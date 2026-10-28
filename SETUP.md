# MAANG Prep: setup guide

This folder has two parts:

- **`site/`**: the website. This is the only folder you upload to Netlify.
- **`setup/`**: the database script, email templates and this guide. Don't upload it.

It takes about 30 minutes, once. Do the steps in order.

---

## Step 1: Create the database tables (Supabase)

1. Open your project at supabase.com → **SQL Editor** (left sidebar) → **New query**.
2. Open `setup/1-setup.sql`, copy everything, paste it into the editor, and click **Run**.
3. You should see "Success. No rows returned". (It's safe to run again later.)

## Step 2: Send emails through Resend

Your domain `neuronixai.site` is already verified in Resend, so you only need a key.

1. Go to **Resend → API Keys → Create API key**.
   - Name: `maang-prep-supabase`
   - Permission: **Sending access**
   - Domain: `neuronixai.site`
2. Copy the key (it starts with `re_`). Resend shows it only once.
3. In **Supabase → Authentication → Emails → SMTP Settings**, turn on **Enable custom SMTP** and fill in:

| Field | Value |
|---|---|
| Sender email | `no-reply@neuronixai.site` |
| Sender name | `MAANG Prep` |
| Host | `smtp.resend.com` |
| Port | `465` |
| Username | `resend` |
| Password | your Resend API key (`re_...`) |

4. Click **Save**.

Never share this key with anyone, including me. It lives only inside Supabase.

## Step 3: Turn on email codes (Supabase)

1. Go to **Authentication → Sign In / Providers → Email**.
   - **Enable Email provider**: ON
   - **Confirm email**: ON
   - **Email OTP Length**: `6` (the site expects 6-digit codes)
   - **Email OTP Expiration**: `600` seconds (10 minutes)
   - Click **Save**.
2. Go to **Authentication → Emails → Templates**.
   - **Confirm signup**:
     - Subject: `Your MAANG Prep verification code`
     - Body: switch to the source/HTML view, delete what's there, and paste everything from `setup/email-confirm-signup.html`.
     - Click **Save**.
   - **Reset password**:
     - Subject: `Your MAANG Prep password reset code`
     - Body: paste everything from `setup/email-reset-password.html`.
     - Click **Save**.

   Both templates use `{{ .Token }}`, which is what makes Supabase email a code instead of a link. Keep it.
3. Optional: in **Authentication → Rate Limits**, raise "emails sent per hour" if many people will sign up at once.

## Step 4: Put the site online (Netlify)

1. Go to **app.netlify.com/drop** and log in (GitHub or email works).
2. Drag the **`site`** folder onto the page. A few seconds later you get a link like `https://random-name-123.netlify.app`.
3. Open that link and check that the sign-in screen appears.
4. Optional: in **Site configuration → Change site name**, pick something nicer, like `maang-prep-akash`.

**To update the site later**, go to **Deploys**, then drag the new `site` folder into the drop area at the bottom.

## Step 5: Use your domain, `prep.neuronixai.site`

1. In Netlify, go to **Domain management → Add a domain** and enter `prep.neuronixai.site`. Click **Verify → Add domain**.
2. Netlify will say "Awaiting External DNS" and show a target like `random-name-123.netlify.app`.
3. Add a DNS record in the same place you added the Resend records for `neuronixai.site`. That's your Shortihost DNS manager (or Cloudflare, if your nameservers point there).

| Type | Name / Host | Value / Points to | TTL |
|---|---|---|---|
| CNAME | `prep` | `random-name-123.netlify.app` (yours) | Auto / 3600 |

   Don't touch the existing Resend records (MX, TXT for SPF/DKIM). You're only adding one new record.
4. Wait 5–30 minutes. Netlify then shows the domain as active and issues the HTTPS certificate automatically.
5. In **Supabase → Authentication → URL Configuration**:
   - **Site URL**: `https://prep.neuronixai.site`
   - **Redirect URLs**: add `https://prep.neuronixai.site/**`

## Step 6: Make yourself the admin

1. Open `https://prep.neuronixai.site` (or the Netlify link) and click **Create an account**. Use **akumi070128@gmail.com**.
2. Enter the 6-digit code from the email.
3. In **Supabase → SQL Editor → New query**, paste everything from `setup/2-make-me-admin.sql` and click **Run**. The check at the bottom should show your email.
4. Reload the site. **Admin: all users** now appears in the side menu and on the home page.

## Step 7: Share it

Send anyone the link. They create an account with a code, and their progress saves to their account.

**What you see as admin:**
- every user's name, email, overall %, per-track progress, current lesson, and last active time (it updates live)
- **Online now**: who is on the site right now and which lesson they're reading

**What everyone sees:** a green "N online" badge with the live count. Personal notes are private to each user.

---

## Troubleshooting

- **The code email never arrives.**
  - Check spam.
  - Check that the SMTP settings in Step 2 are saved.
  - Check Resend → **Emails** for errors.
  - Check Supabase → **Logs → Auth**.
- **"Can't connect to the database"**: `site/config.js` must contain your Supabase URL and publishable key. They're already filled in.
- **The admin link doesn't show**:
  - Re-run `2-make-me-admin.sql` after you've created your account.
  - Make sure you signed up with the same email.
- **A friend forgot their password**: they click **Forgot password?** and get a code. You don't need to do anything.
- **The site seems paused**: free Supabase projects pause after about a week with no visitors. Open the Supabase dashboard and click **Restore project**. No data is lost.
- **To add another admin**: run `2-make-me-admin.sql` with their email instead of yours.
- **To remove a user**: go to Supabase → **Authentication → Users**, click "…" → **Delete user**. Their progress is deleted with them.
