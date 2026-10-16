# Installing Dottie

There are two parts. **Set up once** is for whoever owns this repo: it takes about 15 minutes in a browser, with no Mac tools. **Install on a Mac** is what everyone does, and you can share it as is.

## Set up once (repo owner)

Dottie talks to Google Gemini through a small server (a Cloudflare Worker) that holds your Gemini key, so the key never ships inside the app. GitHub builds that server and the app for you.

1. **Get a Gemini key.** Go to [aistudio.google.com/apikey](https://aistudio.google.com/apikey), click **Create API key**, and copy it. The free tier is enough.
2. **Make a free Cloudflare account** at [dash.cloudflare.com/sign-up](https://dash.cloudflare.com/sign-up). Once you're in, click **Workers & Pages** in the sidebar once, so Cloudflare gives you a `workers.dev` address.
3. **Make a Cloudflare token.** In Cloudflare, click your profile icon (top right), then **My Profile → API Tokens → Create Token**. Next to **Edit Cloudflare Workers**, click **Use template**, then **Continue to summary → Create Token**, and copy the token.
4. **Give both to GitHub.** In this repo on GitHub, go to **Settings → Secrets and variables → Actions → New repository secret** and add:
   - `GEMINI_API_KEY`: the key from step 1
   - `CLOUDFLARE_API_TOKEN`: the token from step 3
   - `DOTTIE_APP_SECRET` (optional): any long random string. With it, your server only answers copies of Dottie built here, so strangers can't use your Gemini quota.
5. **Build it.** In this repo, open the **Actions** tab, click **Release** on the left, then **Run workflow → Run workflow**. In about 10 minutes, **Releases** has a new **Dottie.dmg**.

Run **Release** again whenever you want a new version with the latest changes.

Everyone who installs your build shares your Gemini key's free-tier limits. If people start hitting "rate limit" answers, turn on billing for the key in AI Studio.

## Install on a Mac

You need macOS 14.2 or later. Any Mac works, Apple silicon or Intel.

1. **Download** [Dottie.dmg](https://github.com/IamWasee/dottie/releases/latest/download/Dottie.dmg).
2. **Open it** and drag **Dottie** onto **Applications**.
3. **Open Dottie** from your Applications folder. The first time, macOS says it can't check Dottie for malware, because Dottie isn't registered with Apple (it's a free app). Click **Done**, then:
   - Open **System Settings → Privacy & Security**.
   - Scroll down to the message that says Dottie was blocked and click **Open Anyway**.
   - Enter your password, then click **Open**.

   You only do this once per download.
4. **Allow what Dottie needs.** Dottie lives in your menu bar (top right). Click its icon and allow each item on the list: **Microphone**, **Accessibility**, **Screen Recording** and **Screen content**. macOS may ask you to quit and reopen Dottie after Screen Recording, so let it.
5. **Talk to it.** Hold **control + option**, ask something about what's on your screen, and let go. Dottie answers out loud and can point at things with its blue cursor.

That's it. Some more things to try:

- **Dictate anywhere:** hold the **right Option** key, speak, and let go. Dottie types the cleaned-up text where your cursor is.
- **Hand work off:** say "have a Dot research …" and a background helper works on it and reports back in the notch. The first time, Dottie downloads what Dots need (about 70 MB) by itself.
- **Settings, Dots and history:** click the menu bar icon and open Home.

### Updating

Download the newest Dottie.dmg and drag it into Applications again, choosing **Replace**. Because Dottie isn't registered with Apple, macOS may ask for its permissions again after an update. If something stops working (for example, the shortcut does nothing), open **System Settings → Privacy & Security → Accessibility**, remove Dottie with **−**, and allow it again.

### If something's off

| What you see | What to do |
|---|---|
| "Dottie is damaged and can't be opened" | Drag Dottie into Applications first, then use **Open Anyway** as in step 3. |
| Dottie says it isn't connected | Open Home → Settings → Connection, paste the server address the owner gives you (`https://dottie.<name>.workers.dev`) and click **Check**. Release builds already have it. |
| Holding the shortcut does nothing | Check that Dottie is on under **Accessibility** and **Input Monitoring** in Privacy & Security. |
| It answers "rate limit" | The shared Gemini key hit its free limit. Wait a minute, or the owner can turn on billing. |
