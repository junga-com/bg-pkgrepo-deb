
# Library
# This library implements adding new package content to the local domain repository in the added 'domain' component.
# The main entrypoint is the pkgRepoUpdateLocalDomainComponents function. It processes submitted deb package files that have been
# dropped into the ./incoming/ folder and then rebuilds any Packages files in the 'domain' components of any channels hosted by this
# repo thta have changed. After that update to the staging folder, pkgRepoPublishStagingToWebsite must be called before the changes
# take affect in the repo website.
#
# pkgRepoUpdateLocalDomainComponents is broken up into several helper function located in this library and also uses helper functions
# from the bg-pkgRep.sh library.
#
# The SOR data for this mechanism is in
# * "${repoRoot}/domComponents.awkData" which is an awkData table that records which sub-repo's each added deb file is available in.
# * "${repoRoot}/domainPool/" which is the folder where all new deb files added to this domain our stored. (as opposed to files
#    cached from the upstream repo server)
#
# Typically this is invoked as needed when '''bg-pkgRepo update''' is called.
#
# See Also:
#    man bg_pkgRepo<tab><tab>
#    man bg-pkgRepo<tab><tab>
#    doc/pkgRepo_updateAlgorithm.svg
#    doc/pkgRepo_updateDataFlow.svg


# usage: pkgRepoUpdateLocalDomainComponents
# Process any debs that have been dropped in the ./incoming/ folder and then rebuild the Packages indexes for any 'domain' component
# in all the <channels> in the repo.  The file domComponents.awkData contains the information about which deb belongs in each
# <channel> and <arch>. If there is no longer any local debs in a particular <channel> and <arch>, its Packages files will be removed.
# The net result will be that potentially new incoming deb packages will be added to the ./domainPool/ folder, domComponents.awkData
# will be updated to add those new debs to the incomingChannel, and then the domain component Packages indexes in the staging tree
# will be updated to reflect all the debs in the domain component of any channel.
# TODO: update the Release.last mechanism to reflect this too
#
# The 'doamin' component is added to the the upsteam ubuntu style repository to allow the local domain to add packages specific to
# the domain. The upstream components such as 'main' 'universe' 'multiverse' are passed through and the 'domain' component is added.
function pkgRepoUpdateLocalDomainComponents()
{
	local repoRoot;             configGet -R repoRoot             pkgRepo root            "/var/lib/bg-pkgRepo"
	local repoIncomingChannel;  configGet -R repoIncomingChannel  pkgRepo incomingChannel "focal-dev"

	pkgRepoCleanStagingIfConfigHasChanged

	printf "Processing Incoming Domain Packages\n"

	# make sure the incomingChannel is tagged as the incoming repo.
	fsTouch "${pkgRepoFileAttr[@]}" "${repoRoot}/staging/${repoIncomingChannel}/.cache/incoming"

	### First process any incoming debs that have been dropped in the ./incoming/ folder.
	# this will assert their validity, move them to the ./domainPool/ folder and update domComponents.awkData to record that they are
	# added to the incoming channel.
	local debFile goodCount=0 badCount=0
	for debFile in $(fsExpandFiles "${repoRoot}/incoming"/*); do
		Try:
			_repoImportDeb "$debFile" "$repoIncomingChannel"
			((goodCount++))
		Catch: && {
			((badCount++))
			fsTouch "${pkgRepoFileAttr[@]}" "${repoRoot}/incoming/failed/"
			mv "$debFile" "${repoRoot}/incoming/failed/"
		}
	done

	if ((goodCount+badCount == 0)); then
		printf "   upd: No incomming packages found\n"
	else
		((goodCount>0)) && printf "   upd: %s new packages added to repository\n" "$goodCount"
		((badCount>0)) && printf  "   ${csiHiRed}upd: %s new packages were rejected. see incoming/failed/ folder${csiNorm}\n" "$badCount"
	fi

	### And finally build the staging/<channel>/domain/binary-<arch>/Packages.{xz,gz} index files for any that contain debs in domComponents.awkData
	local channel component arch
	while read -r channel component arch; do
		cd "${repoRoot}/staging/${channel}/"  || assertError
		_repoMakeOneDomainPackagesFile "$channel" "$arch"
	done < <(
		pkgRepoListSubRepos "" "domain" ""
	)
}



# usage: _repoImportDeb <debFile> <channel>
# this will confirm the validity of <debFile>, move it to the ./domainPool/ folder and update domComponents.awkData to record that
# it is a part of the <channel> repo.
# Goal:
#    * new, invalid packaged moved to ./incoming/failed/
#    * new, valid packages moved to ./domainPool/
#    * domComponents.awkData updated to link new valid packages to the <incomingChannel> channel
function _repoImportDeb()
{
	local debFile="$1"
	local channel="${2:-focal-dev}"

	assertFileExists "$debFile" "The file specified to import does not exist"

	local repoRoot;           configGet -R repoRoot             pkgRepo root            "/var/lib/bg-pkgRepo"
	local repoArchitectures;  configGet -R repoArchitectures    pkgRepo architectures   "amd64"; repoArchitectures=($repoArchitectures)

	### extract data from deb file (and/or .changes file)
	local -A debData=()
	parseDebControlFile "debData" "$(dpkg-scanpackages "$1" /dev/null 2>/dev/null)"

	### check that it is allowed
	# TODO: implement policy checks here -- signed, signed user authorized, etc...
	if [ "$(awkData_getValue "${repoRoot}/domComponents.awkData".debFile pkgName:"${debData[Package]}" version:"${debData[Version]}")" ] \
		|| [ -e "${repoRoot}/domainPool/${debFile##*/}" ]; then
		assertError -v debFile -v Package:debData[Package] -v Version:debData[Version] "this deb package file can not be imported into the repository because the same package name and version already exists in the repository"
	fi

	### add entries in domComponents.awkData
	# TODO: this block only does the old way where 'all' goes into each supoorted arch. Support the new way as an option
	local arches="${debData[Architecture]}"
	if [ "$arches" == "all" ]; then
		arches=("${repoArchitectures[@]}")
	fi
	assertNotEmpty arches -v debFile "could not determine the architecture for deb package file"

	# channel arch pkgName version debFile
	#
	# focal   amd64 bg-core 1.0.0 domainPool/bg-core_1.0.0_all.deb
	# focal   amd64 bg-dev  1.0.0 domainPool/bg-dev_1.0.0_all.deb
	import bg_awkDataQueries.sh ;$L1;$L2
	local tmpFile; bgmktemp tmpFile
	local arch; for arch in "${arches[@]}"; do
		printf "%-20s %-20s %-8s %-20s %-13s %s\n" "$channel" "domain" "$arch" "${debData[Package]}" "${debData[Version]}" "domainPool/${debFile##*/}" >> "$tmpFile"
		# TODO: remove older versions of this package. decide on policy -- are multiple versions allowed so clients can choose an earlier version?
	done

	### commit the transaction by moving the debFile to the domainPool and appending the entries to domComponents.awkData
	mv "$debFile" "${repoRoot}/domainPool/"
	if [ ! -f "${repoRoot}/domComponents.awkData" ] || [ "$(wc -l "${repoRoot}/domComponents.awkData" | gawk '{print($1)}')" -lt 2 ]; then
		printf "%-20s %-20s %-8s %-20s %-13s %s\n\n" channel component arch pkgName version debFile  > "${repoRoot}/domComponents.awkData"
	fi
	cat "$tmpFile" >> "${repoRoot}/domComponents.awkData"

	bgmktemp --release tmpFile
}


# usage: _repoMakeOneDomainPackagesFile <channel> <arch>
# This creates the files staging/<channel>/domain/<arch>/Packages.{xz,gz} that list the debs included in the <channel>,domain,<arch>
# subRepo. All the local domain deb package files are in the ./domainPool/ folder so we can't simply point dpkg-scanpackages at that
# folder. Instead, the domComponents.awkData file contains entries assciating each deb package file with the (<channel>,<arch>) pairs
# it should be included in. Note that the component is hard coded to 'domain' to reflect that this repo only adds packages to the
# domain component as not to change the base OS components
#
# After this, the top level Realease file for the repo needs to be updated to reflect the new Packages index
# Goals:
#    * Package.{gz,xz} files reflect the records in domComponents.awkData for this <channel> and <arch>
#    * The legacy Release file is created for this <channel> and <arch>
#    * if <channel> is not mirrored (a new channel added by this repo), a Release.domRepo file is created in its root
function _repoMakeOneDomainPackagesFile()
{
	local channel="$1"
	local arch="$2"

	local repoRoot;             configGet -R repoRoot             pkgRepo root            "/var/lib/bg-pkgRepo"
	local binFolder="${repoRoot}/staging/${channel}/domain/binary-$arch"

	# make sure the bin folder exists
	fsTouch "${pkgRepoFileAttr[@]}"  "${binFolder}/.cache/"

	# write the legacy Release file in the sub-repo for compatibility with old clients
	if fsIsNewer "${repoRoot}/staging/${channel%%-*}/Release" "${binFolder}/Release"; then
		dedent "
			Origin: $(gawk '/^Origin:/ {print $2}' ${repoRoot}/staging/${channel%%-*}/Release)
			Label: $(gawk '/^Label:/ {print $2}' ${repoRoot}/staging/${channel%%-*}/Release)
			Version: $(gawk '/^Version:/ {print $2}' ${repoRoot}/staging/${channel%%-*}/Release)
			Archive: $channel
			Component: domain
			Architecture: $arch
		" >  "${binFolder}/Release"
	fi

	# create the Packages file by querying domComponents.awkData for the files in this sub-repo and using dpkg-scanpackages to
	# format the paragraph for each of them
	local debFile debCount=0
	for debFile in $(awkData_getValue "${repoRoot}/domComponents.awkData".debFile channel:$channel component:domain arch:$arch | sort); do
		# the dpkg-scanpackages cmd outputs the paragraph about the package but the Filename: line will be the wrong relative
		# path so the gawk script fixes that.
		dpkg-scanpackages "${repoRoot}/www/ubuntu/$debFile" /dev/null  2>/dev/null | gawk '
			/^Filename:/ {print("Filename: '"$debFile"'"); next}
			{print($0)}
		'
		((debCount++))
	done  > "${binFolder}/.cache/Packages"

	# if the Packages file is different from the last time, make new compressed versions
	if fsIsDifferent "${binFolder}/.cache/Packages"{,.last} || [ ! -f "${binFolder}/Packages.gz" ] || [ ! -f "${binFolder}/Packages.xz" ]; then
		# Make the gz and xz compressed files and remove the uncompressed one.
		rm -f "${binFolder}/Packages."*
		cp "${binFolder}/.cache/Packages" "${binFolder}/Packages"
		_repoCompress "${binFolder}/Packages"   gz xz
		cp "${binFolder}/.cache/Packages"{,.last}

		# rm the Release files to indicate that they will have to be rebuilt because at least this one Package file has changed
		rm -f "${repoRoot}/staging/${channel}/Release"{,.gpg} "${repoRoot}/staging/${channel}/InRelease"
		printf "   ${csiBold}%s/domain${csiNorm}: Rebuilt Packages index with %s packages\n" "$channel" "$debCount"
	fi
}
