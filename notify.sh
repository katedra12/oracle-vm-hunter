#!/usr/bin/env bash
# Tells the owner through a GitHub issue that @mentions their main account (both accounts get
# an email and a GitHub app push). One issue per event; outside Actions (no GH_TOKEN) it only logs.
#
#   notify.sh got <ocpus> <gb> <zone>   ·   notify.sh done   ·   notify.sh broken <run url>
set -uo pipefail
state=all
case $1 in
  got)  title="Got the Oracle VM: $2 OCPU / $3 GB in $4"
        body="The hunter got **nora-prod** ($2 OCPU / $3 GB, $4) at $(TZ=Europe/Warsaw date '+%F %T').

@erktiky: when the PC is on, \`nora-oci-hunt.service\` finishes the setup by itself (public IP, data volume), then grows the VM to 2/12 if needed. This hunter keeps trying the 2/12 resize until then." ;;
  done) title="Oracle VM is 2 OCPU / 12 GB: hunt finished"
        body="**nora-prod** is 2 OCPU / 12 GB ($(TZ=Europe/Warsaw date '+%F %T')). The hunt workflow switches itself off.

@erktiky: nothing to do here; the PC's \`nora-oci-hunt.service\` turns the server's own neko on next time it runs." ;;
  broken) title="The Oracle VM hunter has a problem"
        body="Oracle gave 5 unexpected answers in a row: $2

@erktiky: it keeps retrying every ~10 minutes. Close this issue once it's fixed (a new one opens if it happens again)."
        state=open ;;
  *) exit 2 ;;
esac
echo "notify: $title"
[[ -n ${GH_TOKEN:-} ]] || exit 0
if [[ -z $(gh issue list --state "${state:-all}" --search "in:title \"$title\"" --json number --jq '.[0].number') ]]; then
  gh issue create --title "$title" --body "$body" >/dev/null || echo "notify: couldn't open the issue"
fi
