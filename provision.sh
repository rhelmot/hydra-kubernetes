#!/usr/bin/env bash

max() {
	echo "$@" | tr ' ' '\n' | sort -n | tail -n1
}

min() {
	echo "$@" | tr ' ' '\n' | sort -n | head -n1
}

main() {
	CONFIG="$(kubectl get deployments -l app=hydra,role=worker -o json)"
	STATUS="$(hydra-queue-runner --status)"

	if [[ $(jq -r '.items.[] | .metadata.name' <<<"$CONFIG" | wc -l) != $(jq -r '.items.[] | .metadata.annotations.machineType' <<<"$CONFIG" | wc -l) ]]; then
		echo "Error: you have deployments with duplicate machineType annotations"
		exit 1
	fi

	result=()

	for machineType in $(jq -r '.items.[] | .metadata.annotations.machineType' <<<"$CONFIG"); do
		config="$(jq --arg machineType "$machineType" '.items.[] | select(.metadata.annotations.machineType == $machineType)' <<<"$CONFIG")"
		status="$(jq --arg machineType "$machineType" '.machineTypes[$machineType]' <<<"$STATUS")"

		runnable="$(jq -r '.runnable' <<<"$status")"
		running="$(jq -r '.running' <<<"$status")"
		[[ $runnable == null ]] && runnable=0
		[[ $running == null ]] && running=0

		deploymentName="$(jq -r '.metadata.name' <<<"$config")"
		replicas="$(jq -r '.spec.replicas' <<<"$config")"
		runnablesPerMachine="$(jq -r '.metadata.annotations.runnablesPerMachine' <<<"$config")"
		ignoredRunnables="$(jq -r '.metadata.annotations.ignoredRunnables' <<<"$config")"
		minMachines="$(jq -r '.metadata.annotations.minMachines' <<<"$config")"
		maxMachines="$(jq -r '.metadata.annotations.maxMachines' <<<"$config")"
		userName="$(jq -r '.metadata.annotations.userName' <<<"$config")"

		wanted=$(($(max $((runnable + running - ignoredRunnables)) 0) / runnablesPerMachine))
		allowed=$(min $(max $wanted $minMachines) $maxMachines)
		needed=$(max $allowed $running)
		delta=$(($needed - $replicas))
		if [[ $delta < 0 ]]; then
			verb="removing $((-$delta)) machines"
		elif [[ $delta > 0 ]]; then
			verb="adding $delta machines"
		else
			verb="no change"
		fi
		echo "Machine type $machineType has $runnable runnables, $running running, wants $wanted machines, has $replicas machines, will get $needed machines, $verb"

		if [[ $delta != 0 ]]; then
			kubectl scale --replicas=$needed deployment $deploymentName
		fi

		podSelector="$(jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")' <<<"$config")"
		for podIP in $(kubectl get pods -o json -l "$podSelector" | jq -r '.items.[] | select(.metadata.deletionTimestamp == null) | .status.podIP | select(. != null)' | sort -u); do
			hostKey="$(ssh-keyscan -t ed25519 $podIP | tail -n1 | cut -d' ' -f 2- | base64 -w0)"
			# hmmm.... resilience
			if [[ -z "$hostKey" ]]; then
				hostKey="$(grep $podIP $NIX_REMOTE_SYSTEMS | cut -d' ' -f7)"
			fi
			maxJobs=1
			speedFactor=1
			privKey=-
			archOs=${machineType%:*}
			if [[ $machineType == *:* ]]; then
				featuresList=${machineType#*:}
			else
				featuresList=-
			fi

			if [[ -n "$hostKey" ]]; then
				echo "ssh://$userName@$podIP $archOs $privKey $maxJobs $speedFactor $featuresList $featuresList $hostKey" >>$NIX_REMOTE_SYSTEMS.tmp
			fi
		done
	done

	if ! diff -u $NIX_REMOTE_SYSTEMS $NIX_REMOTE_SYSTEMS.tmp; then
		mv $NIX_REMOTE_SYSTEMS.tmp $NIX_REMOTE_SYSTEMS
	else
		rm -f $NIX_REMOTE_SYSTEMS.tmp
	fi
}

main
