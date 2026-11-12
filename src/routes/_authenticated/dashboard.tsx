import { createFileRoute } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { supabase } from "@/integrations/supabase/client";
import type { Database } from "@/integrations/supabase/types";
import { isExpired, useRole, useUser } from "@/lib/auth";

export const Route = createFileRoute("/_authenticated/dashboard")({
  head: () => ({
    meta: [
      { title: "Dashboard — Shifo" },
      { name: "description", content: "Your Shifo prescriptions dashboard." },
      { property: "og:title", content: "Dashboard — Shifo" },
      { property: "og:description", content: "Your Shifo prescriptions dashboard." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
      { name: "robots", content: "noindex" },
    ],
  }),
  component: Dashboard,
});

type Rx = Database["public"]["Tables"]["prescriptions"]["Row"] & {
  medicines: { brand_name: string; generic_name_xpn: string } | null;
};

function Dashboard() {
  const { user } = useUser();
  const { data: role, isLoading } = useRole(user?.id);
  if (!user || isLoading) return <main className="mx-auto max-w-5xl px-4 py-12 text-muted-foreground">Loading…</main>;
  return (
    <main className="mx-auto max-w-5xl px-4 py-12">
      <p className="text-sm font-semibold uppercase tracking-wider text-primary">{role ?? "no role"}</p>
      <h1 className="mt-1 text-3xl font-semibold">Hello, {user.user_metadata?.["full_name"] || user.email}</h1>
      <div className="mt-8">
        {role === "doctor" && <DoctorView uid={user.id} />}
        {role === "pharmacist" && <PharmacistView uid={user.id} />}
        {role === "patient" && <PatientView uid={user.id} />}
      </div>
    </main>
  );
}

function StatusBadge({ rx }: { rx: Rx }) {
  if (rx.status === "dispensed") return <Badge variant="secondary">Dispensed</Badge>;
  if (rx.status === "cancelled") return <Badge variant="outline">Cancelled</Badge>;
  if (isExpired(rx.expires_at)) return <Badge variant="destructive">Expired</Badge>;
  return <Badge variant="success">Active</Badge>;
}

function RxCard({ rx, children }: { rx: Rx; children?: React.ReactNode }) {
  return (
    <div className="rounded-2xl border bg-card p-5">
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="font-mono text-lg tracking-widest">{rx.code.replace(/(\d{4})(?=\d)/g, "$1 ")}</p>
          <p className="mt-1 font-semibold">{rx.medicines?.brand_name} <span className="font-normal text-muted-foreground">· {rx.medicines?.generic_name_xpn}</span></p>
        </div>
        <StatusBadge rx={rx} />
      </div>
      <p className="mt-3 text-sm text-muted-foreground">
        Qty {rx.quantity}{rx.dosage ? ` · ${rx.dosage}` : ""} · Issued {new Date(rx.issued_at).toLocaleDateString()} · Expires {new Date(rx.expires_at).toLocaleDateString()}
      </p>
      {children}
    </div>
  );
}

const RX_SELECT = "*, medicines(brand_name, generic_name_xpn)";

function useRxList(key: string, column: "patient_id" | "doctor_id", uid: string) {
  return useQuery({
    queryKey: ["rx", key, uid],
    queryFn: async () => {
      const { data, error } = await supabase.from("prescriptions").select(RX_SELECT).eq(column, uid).order("issued_at", { ascending: false });
      if (error) throw error;
      return data as Rx[];
    },
  });
}

function PatientView({ uid }: { uid: string }) {
  const { data = [] } = useRxList("patient", "patient_id", uid);
  return (
    <section className="space-y-4">
      <div className="rounded-2xl bg-secondary p-4 text-sm text-secondary-foreground">
        Your patient ID (share with your doctor): <span className="font-mono">{uid}</span>
      </div>
      <h2 className="text-xl font-semibold">My prescriptions</h2>
      {data.length === 0 ? <p className="text-muted-foreground">No prescriptions yet.</p> : data.map((rx) => <RxCard key={rx.id} rx={rx} />)}
    </section>
  );
}

function DoctorView({ uid }: { uid: string }) {
  const qc = useQueryClient();
  const { data = [] } = useRxList("doctor", "doctor_id", uid);
  const { data: meds = [] } = useQuery({
    queryKey: ["medicines"],
    queryFn: async () => (await supabase.from("medicines").select("*").order("brand_name")).data ?? [],
  });
  const [busy, setBusy] = useState(false);

  async function issue(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = e.currentTarget;
    const f = new FormData(form);
    setBusy(true);
    const { data: rx, error } = await supabase.from("prescriptions").insert({
      doctor_id: uid,
      patient_id: String(f.get("patient_id")).trim(),
      medicine_id: String(f.get("medicine_id")),
      quantity: Number(f.get("quantity")) || 1,
      dosage: String(f.get("dosage")) || null,
      code: "",
      expires_at: new Date().toISOString(),
    }).select("code").single();
    setBusy(false);
    if (error) { toast.error(error.message); return; }
    toast.success(`Prescription ${rx.code} issued`);
    form.reset();
    qc.invalidateQueries({ queryKey: ["rx"] });
  }

  return (
    <div className="grid gap-8 lg:grid-cols-[360px_1fr]">
      <form onSubmit={issue} className="space-y-4 rounded-2xl border bg-card p-6 h-fit">
        <h2 className="text-lg font-semibold">Issue prescription</h2>
        <div className="space-y-2"><Label htmlFor="patient_id">Patient ID</Label><Input id="patient_id" name="patient_id" required pattern="[0-9a-fA-F-]{36}" /></div>
        <div className="space-y-2">
          <Label htmlFor="medicine_id">Medicine</Label>
          <select id="medicine_id" name="medicine_id" required className="h-9 w-full rounded-md border border-input bg-background px-3 text-sm">
            {meds.map((m) => <option key={m.id} value={m.id}>{m.brand_name} ({m.generic_name_xpn}) {m.strength}</option>)}
          </select>
        </div>
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-2"><Label htmlFor="quantity">Quantity</Label><Input id="quantity" name="quantity" type="number" min={1} defaultValue={1} /></div>
          <div className="space-y-2"><Label htmlFor="dosage">Dosage</Label><Input id="dosage" name="dosage" placeholder="1× daily" /></div>
        </div>
        <p className="text-xs text-muted-foreground">A 12-digit code is generated; valid for 7 days.</p>
        <Button className="w-full" disabled={busy}>Issue</Button>
      </form>
      <section className="space-y-4">
        <h2 className="text-xl font-semibold">Issued prescriptions</h2>
        {data.length === 0 ? <p className="text-muted-foreground">None yet.</p> : data.map((rx) => <RxCard key={rx.id} rx={rx} />)}
      </section>
    </div>
  );
}

function PharmacistView({ uid }: { uid: string }) {
  const [code, setCode] = useState("");
  const [rx, setRx] = useState<Rx | null | undefined>(undefined);
  const { data: pharmacies = [] } = useQuery({
    queryKey: ["pharmacies"],
    queryFn: async () => (await supabase.from("pharmacies").select("*").order("name")).data ?? [],
  });
  const [pharmacyId, setPharmacyId] = useState("");

  async function lookup(e: React.FormEvent) {
    e.preventDefault();
    const clean = code.replace(/\D/g, "");
    if (clean.length !== 12) { toast.error("Code must be 12 digits"); return; }
    const { data } = await supabase.from("prescriptions").select(RX_SELECT).eq("code", clean).maybeSingle();
    setRx((data as Rx) ?? null);
  }

  async function dispense() {
    if (!rx) return;
    const { data, error } = await supabase.from("prescriptions")
      .update({ status: "dispensed", dispensed_by: uid, pharmacy_id: pharmacyId || null })
      .eq("id", rx.id).select(RX_SELECT).single();
    if (error) { toast.error(error.message); return; }
    setRx(data as Rx);
    toast.success("Dispensed");
  }

  const canDispense = rx && rx.status === "active" && !isExpired(rx.expires_at);
  return (
    <section className="max-w-xl space-y-6">
      <form onSubmit={lookup} className="flex gap-2">
        <Input value={code} onChange={(e) => setCode(e.target.value)} placeholder="Enter 12-digit code" inputMode="numeric" className="font-mono tracking-widest" />
        <Button>Look up</Button>
      </form>
      {rx === null && <p className="text-muted-foreground">No prescription found for that code.</p>}
      {rx && (
        <RxCard rx={rx}>
          {canDispense && (
            <div className="mt-4 flex gap-2">
              <select value={pharmacyId} onChange={(e) => setPharmacyId(e.target.value)} className="h-9 flex-1 rounded-md border border-input bg-background px-3 text-sm">
                <option value="">Select pharmacy…</option>
                {pharmacies.map((p) => <option key={p.id} value={p.id}>{p.name}, {p.city}</option>)}
              </select>
              <Button onClick={dispense}>Dispense</Button>
            </div>
          )}
        </RxCard>
      )}
    </section>
  );
}
