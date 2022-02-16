
# Library
# The library that implements the cache ondemand mirroring of an upstream repository.
# The main entrypoint is the pkgRepoUpdateFromUpstream function. It consults the [pkgRepo] section of the system wide config and
# downloads and modifies the indexes from the upstream server as needed. It is broken up into several helper function located in
# this library and also uses helper functions from the bg-pkgRep.sh library. After that update to the staging folder,
# pkgRepoPublishStagingToWebsite must be called before the changes take affect in the repo website.
#
# Typically this is invoked as needed when '''bg-pkgRepo update''' is called.
#
# See Also:
#    man bg_pkgRepo<tab><tab>
#    man bg-pkgRepo<tab><tab>
#    doc/pkgRepo_updateAlgorithm.svg
#    doc/pkgRepo_updateDataFlow.svg



# usage: pkgRepoUpdateFromUpstream
# Update the domain repository mirror of the ubstream OS. If either a ubstream Release file or the local pkgRepo configuration has
# changed, the local domain repository will be rebuilt.
#
# The domain repository is a mirror of the upstream which can filter the upstream repo content to not include parts that are not
# needed or not allowed by the domain policy. The Release files are modified and resigned with the domain's key.
#
# Algorithm:
# For each repo channel (aka suite, like focal,focal-security,etc...), it runs the following steps. These steps are each
# implemented in a function which is idempotent meaning that it can be restarted and it will pick up where it left off..
#    0) pkgRepoUpdateFromUpstream()
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
#       2) _repoRetrieveAndModifyUsedIndexes()
#          iterate the uniqIndexes: list from Releases to download, filter, and recompress the included indexes
#       3) _repoMakeReleaseFile()
#          * scan the folder tree for all indexes that were created and add them to Releases
#          * calculate the hash for each supportedHashes
#          * write the hash algorithm hash algorithm attributes back in with the new index data.
#          * remove the supportedHashes: and uniqIndexes: attributes
#       4) _repoPublishOneChannel()
#          * sign the new Release file with the key whose pub part is in "${repoRoot}/repo-key.asc"
#            the private part of this key must be available on this server and the user may be prompted to provide a pass phrase
#          * Copy the Release and indexes from the staging/ area to the www/dists/ tree
#     5) pkgRepoCleanPublishFolder()
#        iterate the content in the www/dists/ tree and any <channels>, <components>, or <architectures> that are no longer
#        referenced in the current config are removed.
function pkgRepoUpdateFromUpstream()
{
	local repoUpstream;       configGet -R repoUpstream         pkgRepo upstream        "mirrors.edge.kernel.org"
	local repoRoot;           configGet -R repoRoot             pkgRepo root            "/var/lib/bg-pkgRepo"
	local repoChannels;       configGet -R repoChannels         pkgRepo channels        "focal focal-updates focal-backports focal-security" ; repoChannels=(     $repoChannels)
	local repoComponents;     configGet -R repoComponents       pkgRepo components      "main restricted universe multiverse domain"  ; repoComponents=(   $repoComponents)
	local repoArchitectures;  configGet -R repoArchitectures    pkgRepo architectures   "amd64"                                ; repoArchitectures=($repoArchitectures)
	local repoLanguages;      configGet -R repoLanguages        pkgRepo languages       "en"                                   ; repoLanguages=($repoLanguages)
	local repoIncludeSources; configGet -R repoIncludeSources   pkgRepo includeSources  "no"
	local blacklistedPackages; configGet -R blacklistedPackages pkgRepo blacklistedPackages

	creqApply cr_fileObjHasAttributes "${pkgRepoFileAttr[@]}"  "${repoRoot}/staging/"

	pkgRepoCleanStagingIfConfigHasChanged

	echo "Retrieving latest Upstream Release files from '$repoUpstream'"
	local channel
	for channel in "${repoChannels[@]}"; do
		creqApply cr_fileObjHasAttributes "${pkgRepoFileAttr[@]}"  "${repoRoot}/staging/$channel/.cache/"
		cd "${repoRoot}/staging/$channel/.cache" || assertError
		sudo -g pkgrepogroup wget -q --show-progress -N http://$repoUpstream/ubuntu/dists/$channel/Release
	done

	# for any channel that has changed, update our repo to reflect the changes
	for channel in "${repoChannels[@]}"; do
		local changed=""; { [ ! -f "${repoRoot}/staging/$channel/.cache/Release" ] || fsIsDifferent "${repoRoot}/staging/$channel/.cache/Release"{,.last}; } && changed="1"
		if [ "$changed" ] || [ "$forceFlag" ] || [ ! -f "${repoRoot}/staging/${channel}/Release.domRepo" ]; then
			[   "$changed" ] && printf "${csiBold}%s${csiNorm}: Upstream Channel changed\n" "$channel"
			[ ! "$changed" ] && printf "${csiBold}%s${csiNorm}: Forcing update from Upstream Channel\n" "$channel"
			cd "${repoRoot}/staging/$channel" || assertError
			rm -f ".cache/Release.last" # indicate that we are restarting this build so that it will restart if needed
			_repoReduceUpstreamRelease
			_repoRetrieveAndModifyUsedIndexes "$repoUpstream" "$channel" "${repoLanguages[*]}" "$blacklistedPackages"
			# rm the Release files to indicate that they will have to be rebuilt
			rm -f Release{,.gpg} InRelease
			cp .cache/Release{,.last}
		else
			echo "Upstream Channel already sync'd: $channel"
		fi
	done
}




# usage: _repoReduceUpstreamRelease
# This is a helper function for pkgRepoUpdateFromUpstream and assumes the context provided by that function.
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
	if fsIsNewer ".cache/Release" "Release.domRepo"; then
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
	fi
}


# usage: _repoRetrieveAndModifyUsedIndexes <repoUpstream> <channel> <repoLanguages> <blacklistedPackages>
# This is a helper function for pkgRepoUpdateFromUpstream and assumes the context provided by that function.
# Params:
#    <repoUpstream> : the upstream repo to copy indexes from
#    <channel>      : the channel to be operated on
#    <repoLanguages>: strSet of languages supported by this repo. Any other langauge supportted by the upstream repo will be filtered out
#    <blacklistedPackages> : packages that should not be included but might be present in the upstream repo. These will be filtered out
function _repoRetrieveAndModifyUsedIndexes()
{
	local repoUpstream="$1"        ; shift
	local channel="$1"             ; shift
	local repoLanguages=($1)       ; shift
	local blacklistedPackages="$1" ; shift

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
				*Packages)   _repoFilterBlacklistPackages "$uncmpIndex" "Package" "$blacklistedPackages" ;;
				*Sources)    _repoFilterBlacklistPackages "$uncmpIndex" "Package" "$blacklistedPackages" ;;
				*Commands-*) _repoFilterBlacklistPackages "$uncmpIndex" "name"    "$blacklistedPackages" ;;
				*i18n/Index)
					local matchKeep="/^Translation-(${repoLanguages[*]//#/|})(|[.]gz|[.]xz)[[:space:]]*$/"
					bgawk -i '
						$3~/^Translation-/ {deleteLine()}
						$3~'"$matchKeep"' {print $0}
					' "$uncmpIndex"
					;;
				Contents-*)
					# TODO: merge the domain component contents into this upstream contents file
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

# usage: _repoFilterBlacklistPackages <packagesFile> <pkgKey> <blacklistedPackages>
# The Packages, Sources, and Command-<arch> index files are all logically lists of packages. This will scan the input file and remove
# any packages that are listed in the <blacklistedPackages> parameter.  The idea is that the local domain policy can list blacklisted
# pacakges that may exist in the upstream repo being mirrored and they will not be available in the local domain repository.
function _repoFilterBlacklistPackages()
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
