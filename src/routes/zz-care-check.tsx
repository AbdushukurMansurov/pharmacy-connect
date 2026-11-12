import { createFileRoute } from "@tanstack/react-router";
import { CareDashboard } from "@/components/dashboard/CareDashboard";

// Temporary verification page; removed after checking.
export const Route = createFileRoute("/zz-care-check")({
  ssr: false,
  component: () => (
    <main className="mx-auto max-w-6xl px-4 py-10 text-lg">
      <CareDashboard userId="00000000-0000-0000-0000-000000000000" />
    </main>
  ),
});
