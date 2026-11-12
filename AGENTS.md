<!-- LOVABLE:BEGIN -->
> [!IMPORTANT]
> This project is connected to [Lovable](https://lovable.dev). Avoid rewriting
> published git history — force pushing, or rebasing/amending/squashing commits
> that are already pushed — as it rewrites history on Lovable's side and the
> user will likely lose their project history.
>
> Commits you push to the connected branch sync back to Lovable and show up in
> the editor, so keep the branch in a working state.

## What Lovable manages

Rules outside this block are the project's own. Change the pieces below in
Lovable, not by hand. With the [Lovable MCP](https://mcp.lovable.dev)
connected, `send_message` asks Lovable to do it; otherwise ask the user to
use the editor.

- **Database.** Do not add or edit `supabase/migrations/` or `drizzle/`.
  Ask Lovable to change the schema.
- **Generated files.** Do not edit a file whose header says it is automatically
  generated.
- **AI gateway.** Keep model calls on Lovable's gateway, and keep
  `LOVABLE_API_KEY` out of browser code.
- **Connectors.** Lovable provides native connectors. `list_connectors` shows
  which are enabled; `add_connector` only returns the dashboard link. When a
  connector is enabled, calls go through the connector gateway and need
  `LOVABLE_API_KEY`. When Lovable does not provide one, users can bring their
  own key and store it in Secrets.
- **Secrets.** Lovable manages them. Do not put secret values in the repo.
<!-- LOVABLE:END -->

- Roles live in `public.user_roles` (enum patient/doctor/pharmacist), assigned by the `handle_new_user` signup trigger; check them with `has_role()` in RLS — never trust client state for privileges.
- Prescription code (12 digits) and `expires_at` (issued + 7 days) are set by DB triggers and are immutable on update; clients never compute them.
- Patient dashboard modules live in `src/components/dashboard/` and share state through `CareDashboard` (map highlight + care store) so the medicine checker, map and calendar stay connected.
- Pharmacy region/district/hours and per-pharmacy stock are display data in `src/lib/pharmacy-data.ts` because the schema has no columns for them; move them to tables when the schema grows.
- Daily intake logs and demo prescriptions are stored per user in browser localStorage (`src/lib/care-store.ts`) since no intake table exists.
- Dashboard UI copy is Uzbek; code identifiers stay English.
