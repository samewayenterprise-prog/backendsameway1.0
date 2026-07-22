# Admin panel — VPS deploy (46.224.137.253)

The admin panel is the **only** SameWay component that runs on the VPS.
The backend stays on hosted Supabase; the mobile app ships via
TestFlight / Play. The panel holds the service-role key server-side, so
treat this box as sensitive infrastructure.

## One-paste install (Ubuntu, as root)

```bash
# 1 · Node 20 + git
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs git

# 2 · code
git clone https://github.com/samewayenterprise-prog/backendsameway1.0.git /opt/sameway
cd /opt/sameway/admin
npm install --omit=dev

# 3 · secrets  (EDIT the three values before running!)
cat > /etc/sameway-admin.env << 'EOF'
SUPABASE_URL=https://gipmcjmhqvtfcsssaotn.supabase.co
SUPABASE_SECRET_KEY=PASTE_YOUR_sb_secret_KEY_HERE
ADMIN_PASSWORD=PICK_A_LONG_RANDOM_PASSWORD
SESSION_SECRET=PICK_A_DIFFERENT_LONG_RANDOM_STRING
PORT=8080
HOST=127.0.0.1
EOF
chmod 600 /etc/sameway-admin.env

# 4 · service
cp sameway-admin.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now sameway-admin
systemctl status sameway-admin --no-pager
```

The `sb_secret_…` value is in Supabase → Project Settings → API keys.
Generate the two random strings with `openssl rand -hex 24`.

## Reaching it — two modes

**A · SSH tunnel (default, recommended until you attach a domain).**
`HOST=127.0.0.1` means the panel is invisible from the internet. From
your Mac:

```bash
ssh -L 8080:127.0.0.1:8080 root@46.224.137.253
```

then open **http://localhost:8080** in your browser. Credentials never
cross the network unencrypted (they ride inside SSH). Zero TLS setup.

**B · Public on the IP.** Edit `/etc/sameway-admin.env` → `HOST=0.0.0.0`,
then `systemctl restart sameway-admin` and `ufw allow 8080`. Panel is at
http://46.224.137.253:8080. Only do this with a genuinely strong
password, and treat it as temporary: plain HTTP on a public IP means the
password is sniffable on hostile networks. As soon as you have a domain
(e.g. admin.sameway.app → this IP), put Caddy in front for automatic
HTTPS — say the word and that config gets added.

## Updating after a new push

```bash
cd /opt/sameway && git pull && cd admin && npm install --omit=dev
systemctl restart sameway-admin
```

## What the panel does (v0.1)

- **Dashboard** — users, KYC backlog, open reports, upcoming rides,
  confirmed bookings, parcels in flight, push backlog, settled platform
  revenue, latest signups.
- **KYC queue** — every account with an uploaded document still missing
  approval: signed previews of the ID and the selfie (10-min URLs from
  the private bucket), Approve-both / Reject. Reject clears the upload
  so the person recaptures in the app. (Known gap: the app doesn't yet
  show a "rejected — please redo" state; tracked in SEE_STATE.)
- **Reports** — open/in-review queue. Uphold sets `resolved`, which
  fires the automatic reputation penalty; Dismiss closes without one.
- **Users** — search by phone or name, verification badges.
