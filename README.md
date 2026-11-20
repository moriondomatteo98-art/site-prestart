# Pre-Start

Transform Group daily pre-start meeting. Runs on GitHub Pages, stores data in Supabase (project `site-prestart`, Sydney).

- `index.html` – the whole app (supervisor screen, and the worker screen opened from the QR code)
- `manifest.webmanifest`, `icons/` – home-screen app name and Transform icon
- `sw.js` – keeps the app on the phone so it opens with no signal (bump `VERSION` after changing any file)
- `lib/` – Supabase, jsPDF and QR code libraries, kept here so they work offline
- `supabase/schema.sql` – the database setup (tables, security rules, the two worker functions). Safe to run again.

How it works:
- The supervisor logs in, fills in the day and taps **Publish**. That makes a new random QR code for that day.
- Workers scan it with their phone camera (no login, no app). They read the pre-start, tick the acknowledgement,
  pick their name, sign with a finger. The QR code only works on its own date (Sydney time) and stops at midnight.
- The supervisor watches sign-ins live, completes with their own signature, then downloads or shares the PDF.

Security: only the public (publishable) Supabase key is in the code. Row Level Security on every table means only
the supervisor account (listed in `app_owner`) can read or write anything. Workers can only call two database
functions, `get_prestart` and `sign_prestart`, which check the day's QR code and slow down anyone guessing codes.

Adding a supervisor: in Supabase, Authentication → Users → Add user → Send invitation. They get an email, tap the
link, and the app asks for their first name, surname and a password. Every login becomes a supervisor automatically
(sign-ups are off, so only the owner can create logins). To remove one, delete their user in Supabase.
