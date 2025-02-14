#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (C) Semihalf, 2022
# Author: Marek Maślanka <mm@semihalf.com>

SSHPARAMS=""
SCPPARAMS=""
REMOTE_OUT=""

remoteSh()
{
	REMOTE_OUT=$(ssh $SSHPARAMS "$@")
	return ${PIPESTATUS[0]}
}

getLoadedDEKUModules()
{
	remoteSh 'find /sys/module -name .note.deku -type f -exec cat {} \; | grep -a deku_ 2>/dev/null'
	echo "$REMOTE_OUT"
}

getKernelRelease()
{
	remoteSh 'uname --kernel-release'
	echo $REMOTE_OUT
}

getKernelVersion()
{
	remoteSh 'uname --kernel-version'
	echo $REMOTE_OUT
}

originModName()
{
	echo ${1:14}
}

main()
{
	local dstdir="deku"
	local host="${DEPLOY_PARAMS%% *}"
	local extraparams=
	[[ $DEPLOY_PARAMS == *" "* ]] && extraparams="${DEPLOY_PARAMS#* }"
	local sshport=${host#*:}
	local scpport
	if [ "$sshport" != "" ]; then
		scpport="-P $sshport"
		sshport="-p $sshport"
		host=${host%:*}
	fi

	local options="-o ControlPath=/tmp/sshtest -o ControlMaster=auto"
	if [[ "$CHROMEOS_CHROOT" == 1 ]]; then
		if [[ ! -f "$workdir/testing_rsa" ]]; then
			local GCLIENT_ROOT=~/chromiumos
			cp -f "${GCLIENT_ROOT}/src/third_party/chromiumos-overlay/chromeos-base/chromeos-ssh-testkeys/files/testing_rsa" "$workdir"
			chmod 0400 "$workdir/testing_rsa"
		fi
		options+=" -o IdentityFile=$workdir/testing_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -q"
	fi
	SSHPARAMS="$options $extraparams $host $sshport"
	SCPPARAMS="$options $extraparams $scpport"
	unset SSH_AUTH_SOCK

	[[ "$1" == "--getids" ]] && { getLoadedDEKUModules; return $NO_ERROR; }
	[[ "$1" == "--kernel-release" ]] && { getKernelRelease; return $NO_ERROR; }
	[[ "$1" == "--kernel-version" ]] && { getKernelVersion; return $NO_ERROR; }

	local files=$@
	local disablemod=
	local transwait=
	local rmmod=
	local checkmod=
	local insmod=
	# prepare script that tries in loop disable livepatch and do rmmod. Next do insmod
	local reloadscript=
	reloadscript+="max=3\n"
	reloadscript+="for i in \`seq 1 \$max\`; do"
	for file in "$@"; do
		local skipload=
		if [[ "$file" == -* ]]; then
			skipload=1
			files=("${files[@]/$file}")
			file="${file:1}"
			logInfo "Unload $file"
		fi

		local module="$(filenameNoExt $file)"
		local modulename=${module/-/_}
		local modulesys="/sys/kernel/livepatch/$modulename"
		local originname=$(originModName $module)
		disablemod+="[ -d $modulesys ] && echo 0 > $modulesys/enabled\n"
		transwait+="for i in \`seq 1 25\`; do\n"
		transwait+="\t[ ! -d $modulesys ] && break\n"
		transwait+="\t[ \$(cat $modulesys/transition) = \"0\" ] && break\n"
		transwait+="\tsleep 0.2\ndone\n"
		rmmod+="[ -d /sys/module/$modulename ] && rmmod $modulename\n"
		if [ -z $skipload ]; then
			checkmod+="\n[ ! -d $modulesys ] && \\\\"
			insmod+="module=`basename $file`\n"
			insmod+="res=\`insmod $dstdir/\$module 2>&1\`\n"
			insmod+="if [ \$? != 0 ]; then\n"
			insmod+="\techo \"Failed to load $originname. Reason: \$res\"\n"
			insmod+="\texit $ERROR_LOAD_MODULE\n"
			insmod+="fi\n"
			insmod+="for i in \`seq 1 25\`; do\n"
			insmod+="\tgrep -q $modulename /proc/modules && break\n"
			insmod+="\t[ \$? -ne 0 ] && { echo \"Failed to load $modulename\"; exit $ERROR_LOAD_MODULE; }\n"
			insmod+="\techo \"$modulename is still loading...\"\n"
			insmod+="\tsleep 0.05\ndone\n"
			insmod+="for i in \`seq 1 275\`; do\n"
			insmod+="\t[ \$(cat $modulesys/transition) = \"0\" ] && break\n"
			insmod+="\techo \"$originname is still transitioning...\"\n"
			insmod+="\tsleep 0.52\ndone\n"
			insmod+="[ \$(cat $modulesys/transition) != \"0\" ] && { echo \"Failed to apply $modulename \$i\"; exit $ERROR_APPLY_KLP; }\n"
			insmod+="echo \"$originname loaded\"\n"
		fi
	done
	reloadscript+="\n$disablemod\n$transwait\n$rmmod$checkmod\nbreak;\nsleep 1\ndone"
	reloadscript+="\n$insmod"
	echo -e $reloadscript > $workdir/$DEKU_RELOAD_SCRIPT

	ssh $SSHPARAMS mkdir -p $dstdir
	scp $SCPPARAMS $files $workdir/$DEKU_RELOAD_SCRIPT $host:$dstdir/
	logInfo "Loading..."
	remoteSh sh "$dstdir/$DEKU_RELOAD_SCRIPT 2>&1"
	local rc=$?
	if [ $rc == 0 ]; then
		echo -e "${GREEN}Changes applied successfully!${NC}"
	else
		logFatal "----------------------------------------"
		logFatal "$REMOTE_OUT"
		logFatal "----------------------------------------"
		logFatal "Apply changes failed!\nCheck system logs on the device to get more informations"
	fi
	return $rc
}

main $@
