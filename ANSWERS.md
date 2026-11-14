# Answers — Part 5

## Q1. Moving ~40 Ingresses from ingress-nginx to Gateway API with no downtime

**Main idea:** don't switch everything at once. Run the old and the new setup side by side, move traffic a little at a time, and keep a quick way back.

**Steps, in order:**

1. **List what we have.** Export all 40 Ingresses and note which ones use special nginx settings (annotations). Simple ones are easy to move; the special ones need extra work.
2. **Install a Gateway API controller next to ingress-nginx.** Leave nginx running.
3. **Create the new routes** (`Gateway` + `HTTPRoute`) for each app. The `ingress2gateway` tool can convert most of them; check the rest by hand.
4. **Test before moving traffic.** Call each app through the new Gateway, for example `curl --resolve <host>:443:<new-ip>`, and compare with nginx.
5. **Move traffic slowly.** Switch DNS one app at a time, low-risk apps first. Watch for errors and keep nginx ready to switch back.
6. **Clean up.** When nginx gets no traffic for some days, delete the old Ingresses and then uninstall nginx.

**What I expect to break:**

- nginx-specific annotations (rewrites, custom snippets, auth) that have no direct equivalent.
- Different default limits, such as upload size and timeouts.
- TLS certificates that need to be set up for the new Gateway.
- Monitoring and alerts that are based on nginx metrics.
