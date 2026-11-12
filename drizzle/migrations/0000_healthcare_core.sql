CREATE TYPE public.app_role AS ENUM ('patient', 'doctor', 'pharmacist');
CREATE TYPE public.reimbursement_status AS ENUM ('full', 'partial', 'none');
CREATE TYPE public.prescription_status AS ENUM ('active', 'dispensed', 'cancelled');

-- Profiles
CREATE TABLE public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text NOT NULL DEFAULT '',
  phone text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.profiles TO authenticated;
GRANT ALL ON public.profiles TO service_role;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users view own profile" ON public.profiles FOR SELECT TO authenticated USING (auth.uid() = id);
CREATE POLICY "Users update own profile" ON public.profiles FOR UPDATE TO authenticated USING (auth.uid() = id);

-- Roles
CREATE TABLE public.user_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  UNIQUE (user_id, role)
);
GRANT SELECT ON public.user_roles TO authenticated;
GRANT ALL ON public.user_roles TO service_role;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users view own roles" ON public.user_roles FOR SELECT TO authenticated USING (auth.uid() = user_id);

CREATE OR REPLACE FUNCTION public.has_role(_user_id uuid, _role public.app_role)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role)
$$;

-- Doctors can see patient profiles of prescriptions they issued (defined after prescriptions)

-- Signup trigger
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _role public.app_role;
BEGIN
  BEGIN
    _role := COALESCE(NULLIF(NEW.raw_user_meta_data->>'role', ''), 'patient')::public.app_role;
  EXCEPTION WHEN others THEN
    _role := 'patient';
  END;
  INSERT INTO public.profiles (id, full_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.raw_user_meta_data->>'name', ''));
  INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, _role);
  RETURN NEW;
END;
$$;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Medicines
CREATE TABLE public.medicines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  brand_name text NOT NULL,
  generic_name_xpn text NOT NULL,
  dosage_form text,
  strength text,
  manufacturer text,
  reimbursement_status public.reimbursement_status NOT NULL DEFAULT 'none',
  reimbursement_percent integer NOT NULL DEFAULT 0 CHECK (reimbursement_percent BETWEEN 0 AND 100),
  price numeric(12,2),
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.medicines TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.medicines TO authenticated;
GRANT ALL ON public.medicines TO service_role;
ALTER TABLE public.medicines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can view medicines" ON public.medicines FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Pharmacists manage medicines" ON public.medicines FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'pharmacist')) WITH CHECK (public.has_role(auth.uid(), 'pharmacist'));

-- Pharmacies
CREATE TABLE public.pharmacies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  address text NOT NULL,
  city text NOT NULL,
  latitude double precision,
  longitude double precision,
  phone text,
  is_dtsj_partner boolean NOT NULL DEFAULT false,
  owner_id uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.pharmacies TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.pharmacies TO authenticated;
GRANT ALL ON public.pharmacies TO service_role;
ALTER TABLE public.pharmacies ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can view pharmacies" ON public.pharmacies FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Pharmacists add own pharmacy" ON public.pharmacies FOR INSERT TO authenticated
  WITH CHECK (owner_id = auth.uid() AND public.has_role(auth.uid(), 'pharmacist'));
CREATE POLICY "Owners update pharmacy" ON public.pharmacies FOR UPDATE TO authenticated USING (owner_id = auth.uid());
CREATE POLICY "Owners delete pharmacy" ON public.pharmacies FOR DELETE TO authenticated USING (owner_id = auth.uid());

-- Prescriptions
CREATE TABLE public.prescriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code char(12) NOT NULL UNIQUE CHECK (code ~ '^[0-9]{12}$'),
  patient_id uuid NOT NULL,
  doctor_id uuid NOT NULL,
  medicine_id uuid NOT NULL REFERENCES public.medicines(id),
  dosage text,
  quantity integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
  notes text,
  status public.prescription_status NOT NULL DEFAULT 'active',
  issued_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  dispensed_at timestamptz,
  dispensed_by uuid,
  pharmacy_id uuid REFERENCES public.pharmacies(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX prescriptions_patient_idx ON public.prescriptions(patient_id);
CREATE INDEX prescriptions_doctor_idx ON public.prescriptions(doctor_id);
GRANT SELECT, INSERT, UPDATE ON public.prescriptions TO authenticated;
GRANT ALL ON public.prescriptions TO service_role;
ALTER TABLE public.prescriptions ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.generate_prescription_code()
RETURNS text LANGUAGE plpgsql VOLATILE SET search_path = public AS $$
DECLARE _c text;
BEGIN
  LOOP
    _c := lpad(floor(random() * 1e12)::bigint::text, 12, '0');
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.prescriptions WHERE code = _c);
  END LOOP;
  RETURN _c;
END; $$;

CREATE OR REPLACE FUNCTION public.prescriptions_before_insert()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.code IS NULL OR NEW.code = '' THEN NEW.code := public.generate_prescription_code(); END IF;
  NEW.issued_at := COALESCE(NEW.issued_at, now());
  NEW.expires_at := NEW.issued_at + interval '7 days';
  RETURN NEW;
END; $$;
CREATE TRIGGER prescriptions_set_defaults BEFORE INSERT ON public.prescriptions
FOR EACH ROW EXECUTE FUNCTION public.prescriptions_before_insert();

CREATE OR REPLACE FUNCTION public.prescriptions_before_update()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  NEW.code := OLD.code; NEW.issued_at := OLD.issued_at; NEW.expires_at := OLD.expires_at;
  NEW.patient_id := OLD.patient_id; NEW.doctor_id := OLD.doctor_id;
  IF NEW.status = 'dispensed' AND OLD.status <> 'dispensed' THEN
    IF OLD.status <> 'active' OR now() > OLD.expires_at THEN
      RAISE EXCEPTION 'Prescription is expired or not active';
    END IF;
    NEW.dispensed_at := now();
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER prescriptions_guard_update BEFORE UPDATE ON public.prescriptions
FOR EACH ROW EXECUTE FUNCTION public.prescriptions_before_update();

CREATE POLICY "Patients view own prescriptions" ON public.prescriptions FOR SELECT TO authenticated USING (patient_id = auth.uid());
CREATE POLICY "Doctors view issued prescriptions" ON public.prescriptions FOR SELECT TO authenticated
  USING (doctor_id = auth.uid() AND public.has_role(auth.uid(), 'doctor'));
CREATE POLICY "Pharmacists view prescriptions" ON public.prescriptions FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'pharmacist'));
CREATE POLICY "Doctors issue prescriptions" ON public.prescriptions FOR INSERT TO authenticated
  WITH CHECK (doctor_id = auth.uid() AND public.has_role(auth.uid(), 'doctor'));
CREATE POLICY "Doctors cancel own prescriptions" ON public.prescriptions FOR UPDATE TO authenticated
  USING (doctor_id = auth.uid() AND public.has_role(auth.uid(), 'doctor'));
CREATE POLICY "Pharmacists dispense prescriptions" ON public.prescriptions FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(), 'pharmacist'))
  WITH CHECK (public.has_role(auth.uid(), 'pharmacist') AND dispensed_by = auth.uid());

-- Seed data
INSERT INTO public.medicines (brand_name, generic_name_xpn, dosage_form, strength, manufacturer, reimbursement_status, reimbursement_percent, price) VALUES
('Panadol', 'Paracetamol', 'Tablet', '500 mg', 'GSK', 'full', 100, 12000),
('Augmentin', 'Amoxicillin + Clavulanic acid', 'Tablet', '875/125 mg', 'GSK', 'partial', 50, 68000),
('Glucophage', 'Metformin', 'Tablet', '850 mg', 'Merck', 'full', 100, 34000),
('Lipitor', 'Atorvastatin', 'Tablet', '20 mg', 'Pfizer', 'partial', 50, 95000),
('Nurofen', 'Ibuprofen', 'Tablet', '400 mg', 'Reckitt', 'none', 0, 28000),
('Concor', 'Bisoprolol', 'Tablet', '5 mg', 'Merck', 'full', 100, 41000);

INSERT INTO public.pharmacies (name, address, city, latitude, longitude, phone, is_dtsj_partner) VALUES
('Oxy Med Pharmacy', 'Amir Temur Ave 15', 'Tashkent', 41.3111, 69.2797, '+998 71 200 1010', true),
('Dori-Darmon #7', 'Navoi St 42', 'Tashkent', 41.3165, 69.2489, '+998 71 233 4545', true),
('Green Cross', 'Registan St 3', 'Samarkand', 39.6547, 66.9750, '+998 66 210 7788', false),
('Shifo Apteka', 'Mustaqillik Sq 8', 'Bukhara', 39.7681, 64.4556, '+998 65 221 3030', true);