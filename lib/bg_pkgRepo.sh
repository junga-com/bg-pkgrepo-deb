

# Library
# Provides a domain OS repository that serves a subset of an upstream repo and adds a new 'domain' component for new software.
# The rationale for this package is that a domain often needs to control the software used on devices operated by the domain. By
# hosting its own mirror, the domain can configure its devices to only update from the domain repo and network policy may block
# or log direct access to foriegn repositories. The features of this repository focus on 1) reducing/filtering the upstream ubuntu
# content so that only needed parts are available and 2) providing a release process to add new package content and merging it seamlessly
# with the upstream content.
#
# Advantages
#  * the domain can choose to host only needed and approved parts of the distribution so that the size of the repo is smaller
#  * the domain can blacklist packages that would violate policy so that they are not even available to install.
#  * the .debs are cached on demand so the mirror takes little time to setup before clients can start using it.
#  * external bandwidth is reduced and after the cache is populates by one device's update, other devices get the local cached files.
#  * the domain can implement an update policy that determines when its devices will see upstream updates.
#  * the domain can add package content using a safe release cycle process.
#
# Setup:
# To enable the server, set the settings in the [pkgConfig] section of the system wide config (bg-core config ...) to reflect
# the policies of your domain and then activate or apply the pkgConfig.Config plugin with 'bg-configCntr activate pkgRepo:on'.
# See the Config Settings: section for details.
#
# Activating/applying the Config will...
#   * create data in the repoRoot (default /var/lib/bg-pkgRepo/)
#   * setup an nginx virtual host for the ./www/ subfolder
#   * run the update process to initiallize the repo from the upstream mirror so that it is available for use by clients
#   * TODO: after the domain CA is available, make a process to install the correct domain key to sign the repo
#     in the mean time, the admin needs to install a gpg key locally with the private key (or its stub for a card) and copy the
#     pub key to ./www/repo-key.asc
#
# Config Settings:
# These are the config settings that this package recognizes. See man bg-core-config for information on the system wide config.
#      [<sectionName>]<paramName>               <defaultValue>
#      --------------------------               --------------
#      [.]domain                                localhost
#      [pkgRepo]serverName                      pkgrepo.$domain
#      [pkgRepo]root                            /var/lib/bg-pkgRepo
#      [pkgRepo]channels                        focal focal-security focal-updates focal-backports focal-proposed
#      [pkgRepo]components                      main restricted universe multiverse
#      [pkgRepo]architectures                   amd64 i386
#      [pkgRepo]languages                       amd64 i386
#      [pkgRepo]blacklistedPackages             telnet ruby-net-telnet
#
# Note that the default <serverName> uses the <domain> set in the system wide config. Its best to make sure the domain is set but
# you can override it by setting the <serverName> directly. The default will be pkgrepo.localhost which allows local testing on one
# machine.
#
# The typically config task is to eliminate any <channels>, <components>, and <architectures> that will not be used by the domain.
# Its best to start with as few as possible and then add parts as clients report that a needed part is missing.
#
# The [pkgRepo]root setting determines where the Data folder for the repo resides. The default is /var/lib/pkgRepo/
#
# /var/lib/pkgRepo/staging/:
# The current upstream Release and index files are downloaded into hidden ./staging/<channel>/.cache/ folders and processed into
# a new, resigned set of Release and index files that reflect only the channels, components, and architectures that the domain
# whishes to make available and with any blacklisted packages removed. The unhidden files in ./staging/<channel> are the new indexes
# that are in the structure required by the repository standard but are not yet visible via the nginx vhost.
#
# The update process is idempotent so if it is interrupted, it can be restarted after addressing the issue that cause it to stop.
# If a passphrase is set on the private repo key, the user will be prompted for it.
# The last step in the update process will copy the entire non-hidden tree to the ./www/ubuntu/dists/ tree.
#
# /var/lib/pkgRepo/www/:
# The ./www/ subfolder is the root of the nginx vhost. The root has an index file that explains the repository. That page can be
# modified if needed by editting the 'webPage.repoGreetings' system template. The rest of documentroot has automatic directory index
# enabled so people can browse the repo files as expected.
#
# The ./www/dists/ subtree is maintained by the update process and contains the Release and index files that determine the content
# of the repo. The set of Packages.gz files listed in the Release files of each channel link to .deb files in the pool/ subtree.
#
# The ./www/pool/ subtree is configured in the nginx vhost to be a caching reverse proxy to the ./pool/ of the upstream content.
# In this way, the local domain repo can be setup in only the time it takes to retrieve and modify the Release and index files.
# At that point when clients install software, the .deb files that they request will be downloaded from the upsteam into the nginx
# cache and then served to local clients. The nature of .deb package files is that they never change so the cache never goes stale.
# New versions of a package will always get a new version number which is part of the filename.
#
# /var/lib/pkgRepo/domainPool/:
# This folder holds the new packages added to this local repository. It is symlinked from the www/ubuntu/domainPool/ folder. The ./pool/
# web folder is reserved for caching on demand from the upstream. domainPool/ is th esystem of record for local packages and is part
# of the repository state that should be preserved wrt business continuity and disater recovery.
#
# /var/lib/pkgRepo/incoming/:
# When authorized users in the domain submit a package to become part of the domain repository, they are uploaded to this folder
# via scp.  These new packages must not have the same name and version as a package in the upstream repo. They are typically new
# software written by the domain or updated versions of packaged in the upstream which are either renamed or given a version number
# that will sort correctly with the upstream version semantics. Renaming the package makes it so clients in the domain can choose
# to use the official upstream package or the new modified package.
#
# Documentation:
# The ./doc/ folder of this project contains diagrams that might be helpful in understanding this project at a deper level. Some of
# them are linked in the project's readme.md page.
#
#
# See Also:
#    man bg-core-config
#    man bg-pkgRepo
#
# Extra Reference:
# These websites were used as reference when creating this project.
# https://www.debian.org/doc/devel-manuals
# https://debian-handbook.info/browse/stable/sect.package-meta-information.html
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
# https://fpm.readthedocs.io/en/latest/index.html

import bg_creqsLibrary.sh   ;$L1;$L2
import bg_creqs.sh          ;$L1;$L2
import bg_awkDataQueries.sh ;$L1;$L2

declare -ga pkgRepoFileAttr=(-g pkgrepogroup  --perm="rwx rws r-x" -p)

import bg_pkgRepo_upstreamMirror.sh   ;$L1;$L2
import bg_pkgRepo_localDomPackages.sh ;$L1;$L2
import bg_pkgRepo_publish.sh ;$L1;$L2

# usage: pkgRepoUpdateAll
# Do a complete update of the repository.  This includes...
#    * process any deb package files that have been dropped into the ./incoming/ folder.
#          * invalid files moved to ./incoming/failed/
#          * move deb package file to the website ./domainPool/ folder
#          * add an entry(ies) into domComponents.awkData DB to reflect which channels the new package is in (typically [pkgRepo]incomingChannel)
#          * build Packages indexes for any <channel>/domain/ that got new packages as reflected in domComponents.awkData
#    * retrieve lastest indexes from the upstream repo and for any that changed, process our local modifications.
#    * sign any modified <channel>/Release file
#    * publish any modified <channel> by copying/overwriting from staging to the sebsite documentroot.
function pkgRepoUpdateAll()
{
	pkgRepoCleanStagingIfConfigHasChanged
	pkgRepoUpdateLocalDomainComponents
	pkgRepoUpdateFromUpstream
	pkgRepoPublishStagingToWebsite
}



# usage: pkgRepoIsHeathy [-q|--quiet]
# This inspects the state of the $repoRoot/www/ tree to see if it containes a valid repository that clients can use.
#    * is there a signed Release file for each configured <channel>?
#    * does the signature verify?
#    * is the public repository key published at the root of the repo?
#    * is the Release file signed with the key that is published?
#    * are all the indexes listed in the Release file present and with the correct hash?
# The result is returned in a string description and also the exit code.
# Exit Code:
#    0 (true) : success. all configured
#    1 (flase): at least one <channel> is not healthy
function pkgRepoIsHeathy()
{
	local verbosity=1
	while [ $# -gt 0 ]; do case $1 in
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local repoRoot;           configGet -R repoRoot             pkgRepo root            "/var/lib/bg-pkgRepo"
	local repoChannels;       configGet -R repoChannels         pkgRepo channels        "focal focal-updates focal-backports focal-security" ; repoChannels=(     $repoChannels)

	function report()
	{
		echo "err: $channel: $*"
		((result++))
	}

	local result=0
	local channel; for channel in ${repoChannels[@]}; do
		cd "${repoRoot}/www/ubuntu/dists/${channel}/" || assertError
		[ -f Release ]     || report "'Release' is missing"
		[ -f Release.gpg ] || report "'Release.gpg' is missing"
		[ -f InRelease ]   || report "'InRelease' is missing"
		[ -f "${repoRoot}/repo-key.asc" ] || report "The pub key file '$repoRoot/www/repo-key.asc' is missing"
		local verStr; verStr="$(gpg --batch --verify Release.gpg Release)" report "Signature 'Release.gpg' does not verify"
		local signingKey
		IFS=: read -r a a a a signingKey a <<<"$(gpg --show-key --with-colons "${repoRoot}/www/repo-key.asc") | grep ^pub)"
		[[ "$verStr" =~ $signingKey ]] || report "'Release.gpg' is not signed with the key published in the (web server URL)/repo-key.asc"
		verStr="$(gpg --batch --verify InRelease)" report "Signature 'InRelease' does not verify"
		[[ "$verStr" =~ $signingKey ]] || report "'InRelease' is not signed with the key published in the (web server URL)/repo-key.asc"

		# TODO: check the indexes from inside the Release file -- exists and correct hashes
	done
	return $result
}

DeclareCreqClass cr_pkgRepoIsHealthy "
    passMsg: The domain package repository is healthy
    failMsg: The domain package repository has issues
    appliedMsg: Ran 'bg-pkgRepo update' to try to fixx issues
"
function cr_pkgRepoIsHealthy::check() {
	pkgRepoIsHeathy
}
function cr_pkgRepoIsHealthy::apply() {
	pkgRepoUpdateAll
}

# usage: _repoCompress <indexFile> [<compType1> ... <compTypeN>]
# helper function to compress a file with multiple standards and possibly leave the uncompressed file also.
# The default is to remove the original uncompressing file but if '-' is specified among the <compType>, it will remain.
# Params:
#    <indexFile> : the index file to compress. It should NOT be compressed and should NOT have a .gz or .xz extension
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


# usage: pkgRepoListSubRepos <channel> <component> <arch>
# SubRepos are the entities where the Packages files reside. This function will list the ones that this domain repository is
# configured to serve, optionally filtering based on the parameters specified.
# Output:
#   <channel> <component> <arch>
#   <channel> <component> <arch>
#   ...
# Params:
#    <channel>   : if specified, limit the channels listed to this one channel
#    <component> : if specified, limit the components listed to this one component
#    <arch>      : if specified, limit the architectures listed to this one arch
function pkgRepoListSubRepos()
{
	local repoChannels;       configGet -R repoChannels         pkgRepo channels        "focal focal-updates focal-backports focal-security" ; repoChannels=(     $repoChannels)
	local repoIncomingChannel;configGet -R repoIncomingChannel  pkgRepo incomingChannel "focal-dev"
	repoChannels+=($repoIncomingChannel)
	local repoComponents;     configGet -R repoComponents       pkgRepo components      "main restricted universe multiverse domain"  ; repoComponents=(   $repoComponents)
	repoComponents+=(domain)
	local repoArchitectures;  configGet -R repoArchitectures    pkgRepo architectures   "amd64"                                ; repoArchitectures=($repoArchitectures)
	[ "$1" ] && repoChannels=($1)
	[ "$2" ] && repoComponents=($2)
	[ "$3" ] && repoArchitectures=($3)

	local channel component arch
	for channel in "${repoChannels[@]}"; do
		for component in "${repoComponents[@]}"; do
			for arch in "${repoArchitectures[@]}"; do
				printf "%-25s %-25s %s\n" "$channel" "$component" "$arch"
			done
		done
	done
}



# usage: pkgRepoCleanStaging
# delete all the files from the staging area except for indexes in the .cache folder which were downladed from the upstream repo.
# This forces the entire staging content to be rebuilt the next time an update is performed
# This does not remove the indexes downloaded to the .cache/ folders from the upstream server so wget will still be able to use its
# --timestamp feature to only download indexes that are newer. A few of the optional indexes are large so this saves some time when
# doing a complete rebuild
function pkgRepoCleanStaging()
{
	local repoRoot;           configGet -R repoRoot             pkgRepo root            "/var/lib/bg-pkgRepo"
	local repoChannels;       configGet -R repoChannels         pkgRepo channels        "focal focal-updates focal-backports focal-security" ; repoChannels=(     $repoChannels)
	local repoIncomingChannel;configGet -R repoIncomingChannel  pkgRepo incomingChannel "focal-dev"

	local channelList="$(find "${repoRoot}/staging/"* -maxdepth 0 -type d -printf "%f\n" 2>/dev/null)"
	local channel; for channel in $channelList; do
		if ! strSetIsMember "${repoChannels[*]} $repoIncomingChannel"  "$channel" || [ ! -d "${repoRoot}/staging/$channel" ]; then
			rm -rf "${repoRoot}/staging/$channel"
		else
			# this ./* expansion will not remove the hidden files and folders such as .cache/
			rm -rf "${repoRoot}/staging/${channel:-empty}/"* || assertError
			# we only delete the .last files so that we dont have to re-download files from the upstream if wget --timestamps determines
			# they are not chnaged. Also, we dont really have to clean extra files that are no longer needed by the current config
			# because we never have to scan the .cache folder like we do the main staging tree. Deleting the .last file just forces
			# it to recreate the staging content for each index needed by the new Release.
			find "${repoRoot}/staging/${channel:-empty}/.cache/" -name "*.last" -delete 2>/dev/null
		fi
	done
}

# usage: pkgRepoCleanStagingIfConfigHasChanged
# check to see if the [pkgRepo] section in the system wide config has changed and if so, clean the staging folder back to its empty
# state to force a rebuild.
function pkgRepoCleanStagingIfConfigHasChanged()
{
	local forceFlag
	while [ $# -gt 0 ]; do case $1 in
		-f|--force) forceFlag="-f" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	local repoUpstream;       configGet -R repoUpstream         pkgRepo upstream        "mirrors.edge.kernel.org"
	local repoRoot;           configGet -R repoRoot             pkgRepo root            "/var/lib/bg-pkgRepo"
	local repoChannels;       configGet -R repoChannels         pkgRepo channels        "focal focal-updates focal-backports focal-security" ; repoChannels=(     $repoChannels)
	local repoIncomingChannel;configGet -R repoIncomingChannel  pkgRepo incomingChannel "focal-dev"
	local repoComponents;     configGet -R repoComponents       pkgRepo components      "main restricted universe multiverse domain"  ; repoComponents=(   $repoComponents)
	local repoArchitectures;  configGet -R repoArchitectures    pkgRepo architectures   "amd64"                                ; repoArchitectures=($repoArchitectures)
	local repoLanguages;      configGet -R repoLanguages        pkgRepo languages       "en"                                   ; repoLanguages=($repoLanguages)
	local repoIncludeSources; configGet -R repoIncludeSources   pkgRepo includeSources  "no"
	local blacklistedPackages; configGet -R blacklistedPackages pkgRepo blacklistedPackages

	# detect if any configuration has changed. If it has, do a complete rebuild so that parts that may have been removed, will be deleted.
	printfVars repoUpstream repoRoot repoChannels repoComponents repoArchitectures repoLanguages repoIncludeSources blacklistedPackages > "${repoRoot}/staging/.configState"
	if [ "$forceFlag" ] || fsIsDifferent "${repoRoot}/staging/.configState"{,.lastConfig}; then
		echo "The [pkgRepo] section in the system wide config system has changed since the last run so forcing a complete build"
		pkgRepoCleanStaging
		cp "${repoRoot}/staging/.configState"{,.lastConfig}
	fi
}


# usage: pkgRepoCleanPublishFolder
# Remove defunct content from the website that is no longer a part of the repository (because its not referenced in the Release file).
# This removes any content in the www/ tree that is no longer a part of this repository. For example, if the config is changed to
# remove a channel or component, the next time this is ran the corresponding content will be removed. Note that the update process
# fixes up the Release file so that it will not include references to the defunct content. Apt clients will only know about content
# that is present in the Release index but since that defunct content is still in the web vhost documentroot, a hacker could still
# access the defunct content. This function removes the defunct content from the filesystem tree so that it can no longer be
# accessed by any means.
# TODO: rewite this to use the Release files in www/ to determine what is active and delete the content that is not referenced in
#       a Release file.
function pkgRepoCleanPublishFolder()
{
	local repoRoot;           configGet -R repoRoot             pkgRepo root            "/var/lib/bg-pkgRepo"
	local repoChannels;       configGet -R repoChannels         pkgRepo channels        "focal focal-updates focal-backports focal-security" ; repoChannels=(     $repoChannels)
	local repoIncomingChannel;configGet -R repoIncomingChannel  pkgRepo incomingChannel "focal-dev"
	local repoComponents;     configGet -R repoComponents       pkgRepo components      "main restricted universe multiverse domain"  ; repoComponents=(   $repoComponents)
	local repoArchitectures;  configGet -R repoArchitectures    pkgRepo architectures   "amd64"                                ; repoArchitectures=($repoArchitectures)

	local pubRoot="${repoRoot}/www/ubuntu/dists"
	local channelList="$(find "${pubRoot}/"* -maxdepth 0 -type d -printf "%f\n" 2>/dev/null)"
	local channel; for channel in $channelList; do
		if ! strSetIsMember "${repoChannels[*]} $repoIncomingChannel"  "$channel" || [ ! -d "${pubRoot}/$channel" ]; then
			rm -rf "${pubRoot}/$channel"
		else
			local componentList="$(find "${pubRoot}/$channel/"* -maxdepth 0 -type d -printf "%f\n" 2>/dev/null)"
			local component; for component in $componentList; do
				if ! strSetIsMember "${repoComponents[*]} domain"  "$component" || [ ! -d "${pubRoot}/$channel/$component" ]; then
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
