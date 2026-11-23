# ThoughtStream development

The user explicitly stopped automatic app restarts on 2026-10-25 after a restart
loop. Keep `~/Library/Caches/UnfoldNative/restarts-paused` in place. Do not launch,
quit/relaunch, or schedule installation of the main app as development validation
unless the user subsequently asks for that action. Compiling, testing, signing,
and installing with `Scripts/Install-and-Restart.py <app> --no-open` are allowed.
Do not recreate the removed `com.thoughtstream.install-conversation-resize` job,
and never run the one-shot installer as a KeepAlive launchd job.

Other chats may be editing this checkout. Use `Scripts/Build-Isolated.sh` or a
private source snapshot and build directory; preserve unrelated changes. Test
fixtures may start isolated local Codex runtimes without opening the main app.

The user wants models kept on the latest, most capable available releases.
When maintaining model defaults or catalogs, check every supported provider's
current official documentation and the installed runtime's model availability.
Prefer capability over cost or speed unless the user explicitly chooses otherwise.
Use the strongest compatible model actually available to the account; report
newer flagships that the runtime does not yet expose rather than claiming access.
Keep explicit conversation choices and historical test fixtures intact. This
policy does not authorize app restarts or automatic model downloads.
