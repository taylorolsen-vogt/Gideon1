Gideon1
iOS SwiftUI app for the Gideon interface.
Current focus: animated fluid orb with texture-based rendering.

## Supabase Auth Setup

Email signup and password reset links should redirect back into the app with the custom scheme `gideon1://auth/confirmed`.
If confirmations are landing on `localhost`, update the Supabase Auth URL configuration to allow that scheme and make sure email templates use `{{ .RedirectTo }}` where applicable.

That gives the repo a clean landing page.

After you commit that file on GitHub, run these local commands to connect your existing project and push:

cd /Users/taylorolsen-vogt/Gideon1
git init
git add .
git commit -m "Initial local project"
git branch -M main
git remote add origin https://github.com/taylorolsen-vogt/Gideon1.git
git pull origin main --allow-unrelated-histories
git push -u origin main

