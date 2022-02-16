
# Library
# This library implements the process of signed and publishing the data in ./staging/ to the ./www/ document root.
#
# Typically this is invoked as needed when '''bg-pkgRepo update''' is called. The user may be prompted to enter the passphrase of
# the private signing key.
#
# See Also:
#    man bg_pkgRepo<tab><tab>
#    man bg-pkgRepo<tab><tab>
#    doc/pkgRepo_updateAlgorithm.svg
#    doc/pkgRepo_updateDataFlow.svg


# usage: pkgRepoPublishStagingToWebsite
# This publishes each channel hosted by this server from the staging folder to the website folder. Both mirrored and local channels.
# Publishing entails adding the indexes found in the channel's staging folder to its Release file, signing it, and copying the
# Release file and any indexes referenced in the Release file to the website folder.
function pkgRepoPublishStagingToWebsite()
{
	local repoRoot;           configGet -R repoRoot             pkgRepo root            "/var/lib/bg-pkgRepo"
	local repoChannels;       configGet -R repoChannels         pkgRepo channels        "focal focal-updates focal-backports focal-security" ; repoChannels=(     $repoChannels)
	local repoIncomingChannel;configGet -R repoIncomingChannel  pkgRepo incomingChannel "focal-dev"

	# make sure that there is a symlink in the www/ubuntu/ folder to the domainPool. We dont put the domainPool directly in the www/
	# tree because we want to be able to delete the www at any time to cause it to rebuild. There should be no system of record data
	# in the ./www/ nor the ./staging/ folders
	fsTouch "${pkgRepoFileAttr[@]}" "${repoRoot}/www/ubuntu/pool/"
	ln -sf "../../domainPool" "${repoRoot}/www/ubuntu/domainPool"

	for channel in "${repoChannels[@]}" "$repoIncomingChannel"; do
		cd "${repoRoot}/staging/${channel}" || assertError
		if [ ! -f Release.domRepo ] \
			|| fsIsNewer Release.domRepo Release \
		 	|| fsIsNewer "Release" "InRelease" || fsIsNewer "Release" "Release.gpg" \
			|| fsIsDifferent "${repoRoot}/staging/${channel}/Release" "${repoRoot}/www/ubuntu/dists/${channel}/Release"; then
			printf "${csiBold}%s${csiNorm}: Publishing Channel\n" "$channel"
		fi
		_repoMakeReleaseFile
		_repoSignReleaseFile || continue
		_repoPublishOneChannel || continue
	done

	# if the config was changed to remove any components or channels, this will remove that old content
	pkgRepoCleanPublishFolder
}




# usage: _repoMakeReleaseFile
#
# Globals:
#    PWD set to: ${repoRoot}/staging/channel/ folder
function _repoMakeReleaseFile()
{
	if [ ! -f Release.domRepo ] || fsIsNewer Release.domRepo Release; then
		printf "   upd: making Release file\n" "$channel"

		local repoRoot;             configGet -R repoRoot             pkgRepo root            "/var/lib/bg-pkgRepo"
		local repoComponents;     configGet -R repoComponents       pkgRepo components      "main restricted universe multiverse domain"  ; repoComponents=(   $repoComponents)

		# The Release.domRepo file is a template used to create the real Release file. The hash attributes that list the indexes
		# should be present but empty and the code below will fill them in. For mirrored channels, the Release.domRepo is made by
		# stripping down and modifying the upstream Release. For our local channels (e.g. incomingChannel) we copy and modify the
		# Release.domRepo from the mirrored channel that is the base (e.g. focal)

		# For our locally added channels, the Release.domRepo file might not exist so this block copies and modifies the one from
		# the mirrored base channel (i.e. ${channel%%-*})
		if [ -f "${repoRoot}/staging/${channel}/.cache/incoming" ] && fsIsNewer "${repoRoot}/staging/${channel%%-*}/Release.domRepo" "${repoRoot}/staging/${channel}/Release.domRepo"; then
			gawk -v channel="$channel" '
				$1=="Suite:" {printf("Suite: %s\n", channel); next}
				$1=="Components:" {printf("Components: %s\n", "domain"); next}
				$1=="Description:" {printf("Description: %s\n", "Release Channel for "gensub(/^Description:[[:space:]]*/,"","g",$0)); next}
				$1=="uniqIndexes:" {isDeleting=1; next}
				/^[^[:space:]]/ {isDeleting=0}
				!isDeleting {print($0)}
			' "${repoRoot}/staging/${channel%%-*}/Release.domRepo" > "${repoRoot}/staging/${channel}/Release.domRepo"
		fi
		assertFileExists "Release.domRepo" -v channel "Could not make the Release file because Release.domRepo is missing."

		echo "   upd: adding indexes to new Release file with hashes"
		local hashTypes=($(gawk -F: '
			$1=="supportedHashes" {print gensub(/^[[:space:]]*supportedHashes:[[:space:]]*/,"","g",$0)}
		' "Release.domRepo") )
		[ ${#hashTypes[@]} -eq 0 ] && hashTypes=(SHA256)

		# load the data associating the hash attribute names from the Release file and the command used to compute that hash
		if [ ! -f "${repoRoot}/hashCmds.config" ]; then
			dedent "
				MD5Sum=md5sum
				SHA1=sha1sum
				SHA256=sha256sum
				SHA384=sha384sum
				SHA512=sha512sum
			" > "${repoRoot}/hashCmds.config"
		fi
		local -A hashCmds=(
			[size]="stat --format=%s%%20%n"
			[MD5Sum]=md5sum
		)
		local hashType hashCmd
		while IFS='=' read -r hashType hashCmd; do
			[[ "$hashCmd" =~ ^[a-zA-Z0-9]*$ ]] || assertError -v hashType -v hashCmd -f "${repoRoot}/hashCmds.config" "invalid hash command for '$hashType'. Fix it in file '${repoRoot}/hashCmds.config'"
			hashCmds[$hashType]="$hashCmd"
		done < "${repoRoot}/hashCmds.config"

		cp "Release"{.domRepo,}
		rm -f InRelease Release.gpg

		# scan the staging folder for indexes. Contents-<arch>.gz indexes are in the channel root folder and every file found in any of
		# the component folders is an index
		# TODO: replace find with bgfind
		local indexes="$(find "${repoComponents[@]}" domain Contents-*.gz -name .cache -prune -o  -type f -print 2>/dev/null)"

		# create each of the supported hashes for each found index. The output of this block are lines with "<hashType> <filename> <hash>"
		# which is piped into the bgawk cmd.
		local hash file term
		for hashType in "${hashTypes[@]}" size; do
			local hashCmd="${hashCmds[$hashType]}"
			[ ! "$hashCmd" ] && which "${hashType,,}sum" &>/dev/null && hashCmd="${hashType,,}sum"
			[ ! "$hashCmd" ] && assertError -v hashType -v hashCmds -v configFile:"${repoRoot}/hashCmds.config" "unknown hash type. Edit the configFile to add a line '$hashType=<cmd>' where <cmd> is the the command that produces the hash"
			while read -r hash file; do
				printf "%-10s %-60s %s\n" "$hashType" "$file" "$hash"
			done < <($hashCmd $indexes | sed 's/%20/ /g')
		done | bgawk -i '
			# this awk script modifies the Release file inplace to add the indexes and their hash to each hash attribute. The index
			# filenames and hashes are read on stdin from the previous block.
			BEGIN {
				# read the index filenames and hashes from stdin.
				while ( (getline < "/dev/stdin")>0 ) {
					# <hashType> <filename> <hash>
					data[$2][$1]=$3
					if ($1!="size") hashTypes[$1]=1
				}
				# the Release file is presumed to have empty attributes for each supported hashType. This matchRE will match any of them
				matchRE="^("arrayJoini(hashTypes, "|")"):[[:space:]]*$"
			}

			/^[^[:space:]]/ {isDeleting=0}
			isDeleting {deleteLine()}

			$0~matchRE {
				# output the current line before the rest of our output
				print($0); deleteLine();
				hashType=gensub(/:[[:space:]]*$/,"","g", $0)
				for (file in data) {
					cmd="stat --format=%s " file; cmd | getline size; close(cmd)
					printf(" %s %16s %s\n", data[file][hashType], size, file)
				}
			}

			# remove our working attributes that we added to Realease.domRepo during the update process
			/^supportedHashes:/ {deleteLine()}
			/^uniqIndexes:/ {
				deleteLine()
				isDeleting=1
			}

		' Release
	fi
}

# usage: _repoSignReleaseFile
# This is a helper function for pkgRepoUpdateFromUpstream and assumes the context provided by that function.
# Globals:
#    <repoRoot> : path to the repo data
#    <channel>  : the channel being operated on
function _repoSignReleaseFile()
{
	# Sign the Release file
	if fsIsNewer "Release" "InRelease" || fsIsNewer "Release" "Release.gpg"; then
		local signingKey
		IFS=: read -r a a a a signingKey a <<<"$(gpg --show-key --with-colons "${repoRoot}/www/repo-key.asc") | grep ^pub)"
		printf "   upd: signing new Release with key:$signingKey\n" "$channel"

		if [ ! "$signingKey" ] || ! gpg -q --default-key "$signingKey" -abs -o Release.gpg Release || ! gpg -q --default-key "$signingKey" -a --clearsign  -o InRelease Release; then
			echo "!!! WARNING: Release file could not be signed. To retry, rerun this command"
			return 1
		fi
	fi
}


# usage: _repoPublishOneChannel
# This is a helper function for pkgRepoUpdateFromUpstream and assumes the context provided by that function.
# Globals:
#    <repoRoot> : path to the repo data
#    <channel>  : the channel being operated on
function _repoPublishOneChannel()
{
	local fromPath="${repoRoot}/staging/${channel}"
	local toPath="${repoRoot}/www/ubuntu/dists/${channel}"

	# install if it has changed
	if fsIsDifferent "${fromPath}/Release" "${toPath}/Release"; then
		printf "   upd: publishing to website\n" "$channel"
		# copy the index files referenced in this Release
		# TODO: support by-hash to make installation more transactional. make the awk script return the hash and the filename
		while read -r file; do
			fsMakeParent -p "${toPath}/${file}"
			cp "${fromPath}/${file}" "${toPath}/${file}" || assertError
		done < <(gawk '
			# collect any filename that appears in any hash attribute, eliminating dupes by storing it in a map key
			/^ [0-9a-fA-F]{10,135}[[:space:]]/ { files[$3]=1 }
			END {
				# write each unique filename found
				for (file in files)
					print file
			}
		' "Release")

		# copy the Release and sig files
		fsMakeParent -p "${toPath}/Release"
		rm -f "${toPath}/"{Release,Release.gpg,InRelease} || assertError
		cp "${fromPath}/"{Release,Release.gpg,InRelease} "${toPath}/" || assertError
	fi
}
