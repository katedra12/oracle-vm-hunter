#!/usr/bin/env bash
# Hunts the Always Free A1 VM "nora-prod" in Oracle Cloud (Frankfurt) while the owner's PC is off.
# Same job as Nora's deploy/oci/provision-vm.sh + resize-vm.sh, minus everything that needs the
# PC (public IP, data volume, setup over SSH): those run at home once the VM exists.
#
# Every PAUSE_S it looks for the VM; without one it tries each zone at each size (2/12, then
# 1/6); with a 1/6 one it tries to grow it to 2/12, but only until prod moves there (Nora's
# cutover.sh tags the VM nora-cutover; after that the PC resizes, since it checks nobody is
# online first). Stops after HUNT_MINUTES; the workflow then starts the next run.
#
# Exit: 0 keep hunting · 10 the VM is 2/12, or prod moved (nothing left to do here) · 1 broken
#
# Env (from the workflow's secrets): OCI_CLI_CONFIG_FILE, COMPARTMENT, SUBNET, NSG, ADS
# (space-separated zone names), SSH_PUB_FILE. Optional: SIZES ("2:12 1:6"), PAUSE_S (180),
# HUNT_MINUTES (55), ONCE=1 (one round, for testing).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
export TZ=Europe/Warsaw SUPPRESS_LABEL_WARNING=True
log() { echo "$(date '+%F %T') $*"; }
zone() { echo "AD-${1##*-AD-}"; }
# Oracle's error text without IDs (the run logs are public).
why() { grep -m1 -E '"(message|code)"' <<<"$1" | sed -E 's/ocid1\.[a-z]+\.oc1\.[^"'"'"' ]*/ocid1…/g; s/^ +//'; }
capacity() { grep -qiE 'out of (host )?capacity|InternalError.*capacity|TooManyRequests' <<<"$1"; }

c=$COMPARTMENT
read -ra ads <<<"$ADS"
read -ra sizes <<<"${SIZES:-2:12 1:6}"
pause=${PAUSE_S:-180}
end=$((SECONDS + ${HUNT_MINUTES:-55} * 60))
errors=0

image=$(oci compute image list --compartment-id "$c" --operating-system "Canonical Ubuntu" \
  --operating-system-version 24.04 --shape VM.Standard.A1.Flex --sort-by TIMECREATED \
  --sort-order DESC --limit 1 --query 'data[0].id' --raw-output 2>/dev/null)
[[ $image == ocid1.image.* ]] || { log "couldn't find the Ubuntu 24.04 arm64 image"; exit 1; }

# The live nora-prod VM as "id ocpus cutover-tag", "none", or a failure (then nothing is
# launched that round: a failed lookup must never lead to a second VM).
find_vm() {
  local out
  out=$(oci compute instance list --compartment-id "$c" --display-name nora-prod --all \
    --query "data[?\"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'] | [0].[id, \"shape-config\".ocpus, \"freeform-tags\".\"nora-cutover\"]" \
    --output json 2>&1) || { echo "$out"; return 1; }
  [[ -z $out ]] && { echo none; return; }
  jq -r 'if . == null then "none" else map(. // "-" | tostring) | join(" ") end' <<<"$out"
}

# Unexpected answers: keep going, but give up (a red run, so GitHub emails) after 5 in a row.
unexpected() {
  log "unexpected: $1"
  ((++errors < 5)) || { log "5 unexpected answers in a row; stopping"; exit 1; }
}

while :; do
  if ! found=$(find_vm); then
    unexpected "looking for the VM: $(why "$found")"
  elif [[ $found == none ]]; then
    for ad in "${ads[@]}"; do
      for size in "${sizes[@]}"; do
        o=${size%%:*} m=${size##*:}
        if out=$(oci compute instance launch --no-retry --compartment-id "$c" --availability-domain "$ad" \
            --display-name nora-prod --shape VM.Standard.A1.Flex \
            --shape-config "{\"ocpus\":$o,\"memoryInGBs\":$m}" --image-id "$image" \
            --boot-volume-size-in-gbs 50 --subnet-id "$SUBNET" --nsg-ids "[\"$NSG\"]" \
            --assign-public-ip false --hostname-label nora-prod \
            --ssh-authorized-keys-file "$SSH_PUB_FILE" --user-data-file "$here/cloud-init.yaml" \
            --agent-config '{"isMonitoringDisabled":false,"isManagementDisabled":false}' \
            --query data.id --raw-output 2>&1); then
          echo "::add-mask::$(tail -1 <<<"$out")"
          log "got A1 $o OCPU / $m GB in $(zone "$ad")"
          "$here/notify.sh" got "$o" "$m" "$(zone "$ad")"
          errors=0
          break 2
        elif capacity "$out"; then
          log "no capacity: $(zone "$ad") $o:$m"; errors=0
        else
          unexpected "launch $(zone "$ad") $o:$m: $(why "$out")"
        fi
      done
    done
  else
    read -r vm ocpus cutover <<<"$found"
    echo "::add-mask::$vm"
    if (( ${ocpus%.*} >= 2 )); then
      log "the VM is 2 OCPU / 12 GB: nothing left to hunt"
      "$here/notify.sh" done; exit 10
    elif [[ $cutover != - ]]; then
      log "prod moved to the VM: the PC grows it (it checks nobody is online first)"
      exit 10
    elif out=$(oci compute instance update --no-retry --instance-id "$vm" --force \
        --shape-config '{"ocpus":2,"memoryInGBs":12}' --wait-for-state RUNNING 2>&1); then
      log "resized to 2 OCPU / 12 GB"
      "$here/notify.sh" done; exit 10
    elif capacity "$out"; then
      log "resize: no capacity for 2:12 yet"; errors=0
    else
      unexpected "resize: $(why "$out")"
    fi
  fi
  [[ ${ONCE:-} == 1 ]] && exit 0
  ((SECONDS + pause < end)) || exit 0
  sleep "$pause"
done
