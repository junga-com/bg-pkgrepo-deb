

# See Also:
# https://www.debian.org/doc/manuals/debian-reference/ch02.en.html#_debian_package_management_internals
# https://www.linuxuprising.com/2021/01/apt-key-is-deprecated-how-to-add.html
# https://chipsenkbeil.com/posts/applying-gpg-and-yubikey-part-2-setup-primary-gpg-key/
# https://gnupg.org/blog/20201018-gnupg-and-ldap.html
# gpg --with-colons doc : http://www.mit.edu/afs.new/sipb/user/kolya/gpg/gnupg-1.2.1/doc/DETAILS
# https://www.etesync.com/
# https://stosb.com/blog/using-openpgp-keys-for-ssh-authentication/
# https://www.rfc-editor.org/rfc/rfc4880#section-12.2
# https://datatracker.ietf.org/doc/html/draft-dkg-openpgp-abuse-resistant-keystore-00
# https://gnupg.org/blog/20210315-using-tpm-with-gnupg-2.3.html

# usage: pkgRepoCleanStaging
# delete all the files from the staging area except for the Release and Release.last files required to detect when upstream
# Releases change relative to the last one synced with our domain repository
function pkgRepoCleanStaging()
{
	local repoRoot;           configGet -R repoRoot             pkgRepo root            "/var/lib/bg-pkgRepo"
	local repoChannels;       configGet -R repoChannels         pkgRepo channels        "focal focal-updates focal-backports focal-security" ; repoChannels=(     $repoChannels)

	local channelList="$(find "${repoRoot}/staging/"* -maxdepth 0 -type d -printf "%f\n" 2>/dev/null)"
	local channel; for channel in $channelList; do
		if ! strSetIsMember "${repoChannels[*]}"  "$channel" || [ ! -d "${repoRoot}/staging/$channel" ]; then
			rm -rf "${repoRoot}/staging/$channel"
		else
			rm -rf "${repoRoot}/staging/${channel:-empty}/"* || assertError
			# we only delete the .last files so that we dont have to re-download files from the upstream if wget --timestamps determines
			# they are not chnaged. Also, we dont really have to clean extra files that are no longer needed by the current config
			# because we never have to scan the .cache folder like we do the main staging tree. Deleting the .last file just forces
			# it to recreate the staging content for each index needed by the new Release.
			find "${repoRoot}/staging/${channel:-empty}/.cache/" -name "*.last" -delete
		fi
	done
}

# usage: pkgRepoCleanPublishFolder
# This removes any content in the www/ tree that is no longer a part of this repository. For example, if the config is changed to
# remove a channel or component, the next time this is ran the corresponding content will be removed. Note that this is
# typically called from pkgRepoUpdate. The update process fixes up the Release file so that it will not include references to the
# removed content. This function just removes the old content from the tree.
function pkgRepoCleanPublishFolder()
{
	local repoRoot;           configGet -R repoRoot             pkgRepo root            "/var/lib/bg-pkgRepo"
	local repoChannels;       configGet -R repoChannels         pkgRepo channels        "focal focal-updates focal-backports focal-security" ; repoChannels=(     $repoChannels)
	local repoComponents;     configGet -R repoComponents       pkgRepo components      "main restricted universe multiverse"  ; repoComponents=(   $repoComponents)
	local repoArchitectures;  configGet -R repoArchitectures    pkgRepo architectures   "amd64"                                ; repoArchitectures=($repoArchitectures)

	local pubRoot="${repoRoot}/www/ubuntu/dists"
	local channelList="$(find "${pubRoot}/"* -maxdepth 0 -type d -printf "%f\n" 2>/dev/null)"
	local channel; for channel in $channelList; do
		if ! strSetIsMember "${repoChannels[*]}"  "$channel" || [ ! -d "${pubRoot}/$channel" ]; then
			rm -rf "${pubRoot}/$channel"
		else
			local componentList="$(find "${pubRoot}/$channel/"* -maxdepth 0 -type d -printf "%f\n" 2>/dev/null)"
			local component; for component in $componentList; do
				if ! strSetIsMember "${repoComponents[*]}"  "$component" || [ ! -d "${pubRoot}/$channel/$component" ]; then
					rm -rf "${pubRoot}/$channel/$component"
				else
					local architectureList="$(find "${pubRoot}/$channel/$component/binary-"* -maxdepth 0 -type d -printf "%f\n" 2>/dev/null)"
					local architecture; for architecture in $architectureList; do
						if ! strSetIsMember "${repoArchitectures[*]}"  "${architecture#binary-}" || [ ! -d "${pubRoot}/$channel/$component/$architecture" ]; then
							rm -rf "${pubRoot}/$channel/$component/$architecture"
						fi
					done
				fi
			done
		fi
	done
}

# usage: pkgRepoUpdate
# Update the domain repository mirror of the ubstream OS. If either a ubstream Release file or the local pkgRepo configuration has
# changed, the local domain repository will be rebuilt.
#
# The domain repository is a mirror of the upstream which can filter the upstream repo content to not include parts that are not
# needed or not allowed by the domain policy. The Release files are modified and resigned with the domain's key.
#
# Algorithm:
# For each repo channel (aka suite, like focal,focal-security,etc...), it runs the following steps. These steps are each
# implemented in a function which is idempotent meaning that it can be restarted and it will pick up where it left off..
#    0) pkgRepoUpdate()
#       retrieve the Release file for each channel served locally and store them in the <channel>/.cache/ folder
#       For each Release file that is newer than the last update, the remaining steps are performed.
#       1) _repoReduceUpstreamRelease()
#          copy the Release file from the .cache/ and modify it reflect what is inluced in the domain repo.
#          modifications...
#             * removes all hash algorithm attributes which each contains the list of included indexes
#             * It determines which hash algorithms were included in the original Release and writes that list in a new attribute "supportedHashes:"
#             * It makes a list of unique included indexes, removing ones that are not configured for the local domain repo and
#               also choosing just one of multiple compression files ( <index>, <index>.gz, <index>.xz becomes just <index>.gz )
#               It writes this list in the new "uniqIndexes:" attribute so that later steps can use it.
#             * changes the Components: and Architectures: attributes to reflect just what the domain repo is configured for.
#             * changes the Acquire-By-Hash: attribute to no (unit we add support for that)
#       2) _repoRetrieveUsedIndexes()
#          iterate the uniqIndexes: list from Releases to download, filter, and recompress the included indexes
#       3) _repoMakeIndexSectOfRelease()
#          * scan the folder tree for all indexes that were created and add them to Releases
#          * calculate the hash for each supportedHashes
#          * write the hash algorithm hash algorithm attributes back in with the new index data.
#          * remove the supportedHashes: and uniqIndexes: attributes
#       4) _repoInstallIndexes()
#          * sign the new Release file with the key whose pub part is in "${repoRoot}/repo-key.asc"
#            the private part of this key must be available on this server and the user may be prompted to provide a pass phrase
#          * Copy the Release and indexes from the staging/ area to the www/dists/ tree
#     5) pkgRepoCleanPublishFolder()
#        iterate the content in the www/dists/ tree and any <channels>, <components>, or <architectures> that are no longer
#        referenced in the current config are removed.
function pkgRepoUpdate()
{
	local forceFlag
	while [ $# -gt 0 ]; do case $1 in
		-f|--force) forceFlag="-f" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	local repoUpstream;       configGet -R repoUpstream         pkgRepo upstream        "mirrors.edge.kernel.org"
	local repoRoot;           configGet -R repoRoot             pkgRepo root            "/var/lib/bg-pkgRepo"
	local repoChannels;       configGet -R repoChannels         pkgRepo channels        "focal focal-updates focal-backports focal-security" ; repoChannels=(     $repoChannels)
	local repoComponents;     configGet -R repoComponents       pkgRepo components      "main restricted universe multiverse"  ; repoComponents=(   $repoComponents)
	local repoArchitectures;  configGet -R repoArchitectures    pkgRepo architectures   "amd64"                                ; repoArchitectures=($repoArchitectures)
	local repoLanguages;      configGet -R repoLanguages        pkgRepo languages       "en"                                   ; repoLanguages=($repoLanguages)
	local repoIncludeSources; configGet -R repoIncludeSources   pkgRepo includeSources  "no"
	local blacklistedPackages; configGet -R blacklistedPackages pkgRepo blacklistedPackages

	import bg_creqsLibrary.sh  ;$L1;$L2
	import bg_creqs.sh         ;$L1;$L2

	creqApply cr_fileObjHasAttributes -u pkgrepouser -g pkgrepogroup  --perm="d rwx rws r-x"  "${repoRoot}/staging/"

	# detect if any configuration has changed. If it has, do a complete rebuild so that parts that may have been removed, will be deleted.
	printfVars repoUpstream repoRoot repoChannels repoComponents repoArchitectures repoLanguages repoIncludeSources blacklistedPackages > "${repoRoot}/staging/.configState"
	if fsIsDifferent "${repoRoot}/staging/.configState"{,.last}; then
		echo "[pkgRepo] config has changed since the last run so forcing a complete build"
		forceFlag="-f"
		pkgRepoCleanStaging
		cp "${repoRoot}/staging/.configState"{,.last}
	fi

	echo "Retrieving latest Upstream Release files from '$repoUpstream'"
	local channel
	for channel in "${repoChannels[@]}"; do
		creqApply cr_fileObjHasAttributes -u pkgrepouser -g pkgrepogroup  --perm="d rwx rws r-x"  "${repoRoot}/staging/$channel/.cache/"
		cd "${repoRoot}/staging/$channel/.cache" || assertError
		sudo -g pkgrepogroup wget -q --show-progress -N http://$repoUpstream/ubuntu/dists/$channel/Release
	done

	# for any channel that has changed, update our repo to reflect the changes
	for channel in "${repoChannels[@]}"; do
		local changed=""; { [ ! -f "${repoRoot}/staging/$channel/.cache/Release" ] || fsIsDifferent "${repoRoot}/staging/$channel/.cache/Release"{,.last}; } && changed="1"
		if [ "$forceFlag" ]; then
			[ ! "$changed" ] && echo "Forcing update of Upstream Channel: $channel"
		fi
		if [ "$changed" ] || [ "$forceFlag" ]; then
			[ "$changed" ] && echo "Upstream Channel changed: $channel"
			cd "${repoRoot}/staging/$channel" || assertError
			rm -f ".cache/Release.last" # indicate that we are restarting this build so that it will restart if needed
			if ! fsIsNewer "Release.domRepo" ".cache/Release"; then
				_repoReduceUpstreamRelease
			fi
			_repoRetrieveUsedIndexes
			_repoMakeIndexSectOfRelease
			_repoInstallIndexes || return
			cp .cache/Release{,.last}
		else
			echo "Upstream Channel already sync'd: $channel"
		fi
	done

	# if the config was changed to remove any components or channels, this will remove that old content
	pkgRepoCleanPublishFolder
}

# usage: _repoReduceUpstreamRelease
# This is a helper function for pkgRepoUpdate and assumes the context provided by that function.
# This reads in the Release file and writes a filtered version to Release. The modified output removes any indexes
# for architectures, languages, or components not supportted by the local domain repo.  The remaining indexes are further filtered
# to remove duplicates that only are different in their compression method. The final list of indexes are written to the new attribute
# "uniqIndexes:". All the index entries under the various hash algorithm attributes are supressed but the hash algorithm attributes
# lines are left in the file as a place holder to preserve the order of attributes (just in case something finds that significant).
# The list of present hash algorithm attributes is written in a new attribute "supportedHashes:"
#
# The two new attributes ("uniqIndexes:" and "supportedHashes:") will be used to reconstruct the final Release file after the indexes
# are potentially modified (e.g. blacklisted packages removed)
#
# The input file is typically the Release file from a full Ubuntu repo mirror.
# Globals:
#    <repoArchitectures>  : an array whose elements are the supported architectures in the domain's repo
#    <repoLanguages>      : an array whose elements are the supported languages (2 letter codes plus _<suffix>) in the domain's repo
#    <repoComponents>     : an array whose elements are the supported components (main, universe,etc..) in the domain's repo
#    <repoIncludeSources> : boolean that indicates if this repo includes source pacakges
function _repoReduceUpstreamRelease()
{
	echo "   upd: reducing Release file to reflect what this repository serves"
	bgawk -v repoArch="${repoArchitectures[@]:-amd64}" \
		  -v repoComp="${repoComponents[*]:-main}" \
		  -v repoLang="${repoLanguages:-en}" \
		  -v repoIncludeSources="$repoIncludeSources" '
		BEGIN {
			spliti(repoArch, repoArchs);
			spliti(repoLang, repoLangs);
			spliti(repoComp, repoComps);
			langRegEx="i18n/Translation-(" joini(repoLangs, "|") ")([.]|$)"
		}
		/^[^[:space:]]+:/ {
			attrName=gensub(/:.*$/,"","g",$0)
			attrValue=gensub(/^[^:]*:[[:space:]]*/,"","g",$0)
		}
		attrName=="Architectures" {
			spliti(gensub(/^[^:]*:/,"","g"), upArchs);
			newLine="Architectures: ";
			for (arch in upArchs)
				if (!(arch in repoArchs))
					rmArchs[arch]=1;
				else
					newLine= newLine " " arch;
			$0=newLine;
			rmArchRegEx="-(" joini(rmArchs, "|") ")[./]"
		}
		attrName=="Components" {
			spliti(gensub(/^[^:]*:/,"","g"), upComps);
			newLine="Components: ";
			for (comp in upComps)
				if (!(comp in repoComps))
					rmComps[comp]=1;
				else
					newLine= newLine " " comp;
			$0=newLine;
			rmCompsRegEx="^(" joini(rmComps, "|") ")/"
		}
		attrName=="Date" {
			printf("%s: %s\n", "Date-Upstream", attrValue)
			# Thu, 23 Apr 2020 17:33:17 UTC
			printf("%s: %s\n", "Date", strftime("%a, %e %b %Y %H:%M:%S %Z"))
			deleteLine()
		}
		# initially we are not supporting the by-hash aliases but its not hard to add it later.
		attrName=="Acquire-By-Hash" {
			printf("%s: %s\n", "Acquire-By-Hash", "no")
			deleteLine()
		}
		/^ [0-9a-fA-F]{10,135}[[:space:]]/ {
			supportedHashes[attrName]=1
			if ( !($3"." ~ rmArchRegEx) \
			     && !(($3 ~ /i18n\/Translation/) && ($3 !~ langRegEx)) \
			     && !($3 ~ rmCompsRegEx) \
				 && !((repoIncludeSources~/(^[[:space:]]*no|0|)[[:space:]]*$/) && ($3 ~ /source\/(Sources|Release)/)) ) {
				filename=$3
				normName=gensub(/([.]xz|[.]gz)$/,"","g",filename)
				fileType=gensub(/(^.*\/)|(([.]xz|[.]gz)$)/,"","g",filename)
				if (!(normName in uniqIndexes) || (uniqIndexes[normName] !~ /[.](gz|xz)$/ ) || (filename ~ /[.]gz$/))
					uniqIndexes[normName]=filename
			}
			deleteLine()
		}
		END {
			printf("%s: %s\n", "supportedHashes", joini(supportedHashes, " "))
			printf("%s: %s\n", "uniqIndexes", "")
			for (i in uniqIndexes)
				printf(" %s\n", uniqIndexes[i])
		}
	' ".cache/Release" > "Release.domRepo"
}


# usage: _repoRetrieveUsedIndexes
# This is a helper function for pkgRepoUpdate and assumes the context provided by that function.
# Globals:
#    <repoUpstream> : the upstream repo to copy indexes from
#    <channel>      : the channel to be operated on
#    <repoLanguages>: strSet of languages supported by this repo
#    <blacklistedPackages> : packages that should not be included but might be present in the upstream repo
function _repoRetrieveUsedIndexes()
{
	echo "   upd: retrieving upstream indexes used by this domain repo"
	local baseURL="http://$repoUpstream/ubuntu/dists/$channel/"

	local indexes="$(gawk -F: '
		/^[^:]*:[[:space:]]*/ {intarget=""}
		$1=="uniqIndexes" {intarget="1"; next}
		intarget {print(gensub(/^[[:space:]]*|[[:space:]]*$/,"","g",$0))}
	' "Release.domRepo")"

	# TODO: --cut-dirs=3 The '3' is based on the mirror URL having exactly one folder like example.com/ubuntu/
	echo  $indexes | tr " " "\n" | wget -q -N -r  -nH --cut-dirs=3 --base="$baseURL" -P .cache -i -

	# process the files
	echo "   upd:  |- processing indexes"
	local index uncmpIndex count=0 total=0
	for index in $indexes; do
		((total++))
		fsMakeParent -p "$index"
		if [ ! -f "$index" ] || fsIsDifferent ".cache/$index"{,.last}; then
			((count++))
			# uncompress in case we need to edit the contents
			if [[ "$index" =~ [.]gz$ ]]; then
				uncmpIndex="${index%.gz}"
				gunzip -f -c ".cache/$index" > "$uncmpIndex" || assertError
			elif [[ "$index" =~ [.]xz$ ]]; then
				uncmpIndex="${index%.xz}"
				unxz -f -c ".cache/$index" > "$uncmpIndex" || assertError
			else
				uncmpIndex="$index"
				cp ".cache/$index" "$uncmpIndex" || assertError
			fi

			case $uncmpIndex in
				*debian-installer/*Packages)   : ;; # the installer Pacakges files is not subject to our blacklist
				*Packages)   repoFilterBlacklistPackages "$uncmpIndex" "Package" "$blacklistedPackages" ;;
				*Sources)    repoFilterBlacklistPackages "$uncmpIndex" "Package" "$blacklistedPackages" ;;
				*Commands-*) repoFilterBlacklistPackages "$uncmpIndex" "name"    "$blacklistedPackages" ;;
				*i18n/Index)
					local matchKeep="/^Translation-(${repoLanguages[*]//#/|})(|[.]gz|[.]xz)[[:space:]]*$/"
					bgawk -i '
						$3~/^Translation-/ {deleteLine()}
						$3~'"$matchKeep"' {print $0}
					' "$uncmpIndex"
					;;
			esac

			case $uncmpIndex in
				Contents-*)          _repoCompress "$uncmpIndex"   gz    ;;
				*/Release) ;; # the top level Release wont be iterated b/c it is the source of the index list
				*i18n/Index) ;;
				*/Sources)           _repoCompress "$uncmpIndex"   gz xz ;;
				*i18n/Translation-*) _repoCompress "$uncmpIndex" - gz xz ;;
				*dep11/icons-*)      _repoCompress "$uncmpIndex"   gz    ;;
				*dep11/Components-*) _repoCompress "$uncmpIndex"   gz xz ;;
				*cnf/Commands-*)     _repoCompress "$uncmpIndex"      xz ;;
				*Packages)           _repoCompress "$uncmpIndex"   gz xz ;;
				*)                   _repoCompress "$uncmpIndex" - gz xz ;;
			esac

			cp ".cache/$index"{,.last} || assertError
		fi
	done
	echo "   upd:  '- ${count} out of ${total} indexes where updated"
}

# usage: repoFilterBlacklistPackages <packagesFile> <pkgKey> <blacklistedPackages>
function repoFilterBlacklistPackages()
{
	local packagesFile="$1"
	local pkgKey="$2"
	local blacklistedPackages="$(strSetNormalize "$3")"

	local awkPkgMatch="/^${pkgKey}:[[:space:]]*(${blacklistedPackages// /|})[[:space:]]*$/"

	bgawk -i '
		/^'"${pkgKey}"':[[:space:]]*/ {inrmPkg=""}
		'"$awkPkgMatch"' {inrmPkg="1"}
		inrmPkg {deleteLine()}
	' "$packagesFile"
}


# usage: _repoCompress <indexFile> [<compType1> ... <compTypeN>]
# helper function to compress a file with multiple standards and possibly leave the uncompressed file also
# Params:
#    <indexFile> : the index file to compress. It should not be compressed and should not have a .gz or .xz extension
#    <compTypeN> : the compression type to apply to the index. one of (- gz xz). '-' means to leave the original uncompressed file
#                  as well as the compressed versions
function _repoCompress()
{
	local index="$1"; shift
	local leaveUncompressed=""
	while [ $# -gt 0 ]; do
		local compType="$1"; shift
		case $compType in
			-)  leaveUncompressed="-" ;;
			gz) gzip -9 -c "$index" > "$index".gz ;;
			xz) xz -f -k "$index" ;;
			*)  assertError "unknown compression type '$compType'"
		esac
	done
	[ ! "$leaveUncompressed" ] && rm "$index"
}


# usage: _repoMakeIndexSectOfRelease
# This is a helper function for pkgRepoUpdate and assumes the context provided by that function.
# Globals:
#    PWD set to: ${repoRoot}/staging/channel/ folder
#    <repoComponents> : asociative array of components that this repo should serve
function _repoMakeIndexSectOfRelease()
{
	echo "   upd: adding indexes to new Release file with hashes"
	local hashTypes=($(gawk -F: '
		$1=="supportedHashes" {print gensub(/^[[:space:]]*supportedHashes:[[:space:]]*/,"","g",$0)}
	' "Release.domRepo") )
	[ ${#hashTypes[@]} -eq 0 ] && hashTypes=(SHA256)

	local -A data=()

	local -A hashCmds=(
		[MD5Sum]="md5sum"
		[SHA1]="sha1sum"
		[SHA256]="sha256sum"
		[SHA384]="sha384sum"
		[SHA512]="sha512sum"
		[size]="stat --format=%s%%20%n"
	)

	cp "Release"{.domRepo,}

	# TODO: replace find with bgfind
	local indexes="$(find "${repoComponents[@]:-main}" Contents-amd64.gz  -type f 2>/dev/null)"

	local hash file term
	for hashType in "${hashTypes[@]}" size; do
		while read -r hash file; do
			data[${file}-${hashType}]="$hash"
		done < <(${hashCmds[$hashType]} $indexes | sed 's/%20/ /g')
	done

	for term in "${!data[@]}"; do
		file="${term%-*}"
		hashType="${term##*-}"
		printf "%-10s %-60s %s\n" "$hashType" "$file" "${data[$term]}"
	done | bgawk -i '
		BEGIN {
			while ( (getline < "/dev/stdin")>0 ) {
				data[$2][$1]=$3
				if ($1!="size") hashTypes[$1]=1
			}
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

		/^supportedHashes:/ {deleteLine()}
		/^uniqIndexes:/ {
			deleteLine()
			isDeleting=1
		}

	' Release
}


# usage: _repoInstallIndexes
# This is a helper function for pkgRepoUpdate and assumes the context provided by that function.
# Globals:
#    <repoRoot> : path to the repo data
#    <channel>  : the channel being operated on
function _repoInstallIndexes()
{
	local fromPath="${repoRoot}/staging/${channel}"
	local toPath="${repoRoot}/www/ubuntu/dists/${channel}"

	# Sign the Release file
	if [ ! -f "InRelease" ] || fsIsNewer "InRelease" "Release"; then
		local signingKey
		IFS=: read -r a a a a signingKey a <<<"$(gpg --show-key --with-colons "${repoRoot}/www/repo-key.asc") | grep ^pub)"
		echo "   upd: signing new Release with key:$signingKey"

		if [ ! "$signingKey" ] || ! gpg -q --default-key "$signingKey" -abs -o Release.gpg Release || ! gpg -q --default-key "$signingKey" -a --clearsign  -o InRelease Release; then
			echo "!!! WARNING: skipping install because the Release file could not be signed. To retry, run ..."
			return 1
		fi
	else
		echo "   upd: Release file was already signed"
	fi

	# install if it has changed
	if fsIsDifferent "${fromPath}/Release" "${toPath}/Release"; then
		echo "   upd: installing new Release and indexes into published folder"
		# copy the index files referenced in this Release
		# TODO: support by-hash to make installation more transactional. make the awk script return the hash and the filename
		while read -r file; do
			fsMakeParent -p "${toPath}/${file}"
			cp "${fromPath}/${file}" "${toPath}/${file}" || assertError
		done < <(gawk '
			/^ [0-9a-fA-F]{10,135}[[:space:]]/ { files[$3]=1 }
			END {
				for (file in files)
					print file
			}
		' "Release")

		# copy the Release and sig files
		fsMakeParent -p "${toPath}/Release"
		rm -f "${toPath}/"{Release,Release.gpg,InRelease} || assertError
		cp "${fromPath}/"{Release,Release.gpg,InRelease} "${toPath}/" || assertError
	else
		echo "   upd: this version has already been installed"
	fi
}
