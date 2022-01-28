# Debian Repository Structure

This article tries to explain how debian package repositories work. I found it difficult to find this information when I wrote the
bg-pkgRepo-deb project so I am documenting what I found here. Note that some of my assertions may be conjecture based on my experience
a nd observations as a long time user of ubuntu. I welcome input to correct any errant information.

I use ubuntu which derives from debian. Even though ubuntu uses the debian standard, it uses that standard differently to provide
its release structure. Much of what I describe will be true for debian and other debian based distributions but the specifics will
be for ubuntu.


## The Big Picture
The debian package repository standard is one of several that are popular among linux distributions. A package repository makes
software available to install on devices. It is a form of app store. When a device is configured to use a particular repository,
users on that device are able to install any of the software contained in the repository easily.

Unlike closed app stores, a linux device can specify which repository makes software available to it and can specify multiple
repositories whose contents are logically combined together in a union. When the same software package name is available from
multiple repositories used by a device, the version numbers of the packages determine which one is installed by default. If two
repositories contain the same exact version of a package name, they are not technically compatible to be used by the same device.

We can think of a particular set of compatible repositories as a logical operating system complete with the full set of software
that is 'approved' to be installed. A running device that uses that repository set gets a subset of the system installed initially
and can then can install other software from the approved set as needed. This is particularly useful in an organization that wants
limit the software running on its devices to an approved set of software.



## The Client Side
Apt is the typical client side software that manages making software from debian repositories available to install. The /etc/apt/sources.list
file and files in /etc/apt/sources.list.d/ combine to define the set of repositories that the device uses. Typically the source.list
file is created and maintained by the OS installation process and configuration utilities. It contains the configuration lines for
the several repositories that make up the official OS release of which some optional ones may be commented out based on the user
preferences during installation and then maintained by the software update utility.

The folder /etc/apt/sources.list.d/ is meant for the user to add additional repositories that add to the base OS repositories. Sometimes
a repository contains a single logical software package. By providing a repository, the software author provides a way not only to
install the software but also to automatically distribute updates.

The command '''apt update''' retrieves the current list of software packages from each repository specified in those files and
makes a local database of the union all packages available. By default, only the latest version of each package is available to install.

After updating the lists from repositories, it is common that some previously installed packages might have new versions available.
The command '''apt upgrade''' will install the newer version of all such packages.

Regardless of which file its resides in, the apt configuration consists of lines that specify these parts.
* base URL : e.g.  archive.ubuntu.com/ubuntu/
* Repository Channel (aka suit): e.g.  focal, focal-updates, xenial-security, etc...
* Repository Components: one or more of main, universe, multiverse, restricted, etc...

'''
deb http://us.archive.ubuntu.com/ubuntu/  focal-updates    main restricted
    '----URL---------------------------'  '--channel--'   '- components--'
'''


## Debian-style Repository Structure
We can think of a logical debian-style repository as a cube because it contains three somewhat independent dimensions.
* Repository Channels (aka suite): determine how software is updated
* Repository Components: determine the set of software available
* Repository Architectures: determines the specific files appropriate for a device's CPU

Unfortunately these are only somewhat independent because Architectures are nested under Components and Components are nested under
Channels (aka suite) and the actual thing that devices can add to their apt configurations are triplets of all three. This means that
if I choose an update strategy (e.g. only security updates) I must consider the appropriate channels to include for each Component
that I want to use and its possible that some components might come from a different server and the channel names and policies might
be different.

The term 'repository' is overloaded and is hard to use consistently. In one sense its a website like archive.ubuntu.com. In another
sense its group of channels (aka suit) that correspond to a given release (i.e. the Ubuntu focal repository). And, yet again it is
the triplet configured on a source.list configuration line that is actually the thing that defines a set of software that can be used.


### Repository Channels (aka suite): Combining Repositories to Create a Release Strategy
Ubuntu uses the feature of combining multiple software sources (aka one use of the term repositories) on the client to implement a
release strategy. Each major release of ubuntu consists of the following top level channels (aka suites).

* <releaseName> : the base distribution which changes infrequently if at all
* <releaseName>-security : as security issues are found their fixes are released here
* <releaseName>-updates  : feature improvements
* <releaseName>-backports: significant new versions backported from a newer major version
Where <releaseName> is focal, hirsute, impish, jammy, etc... and are names tha tcorrespond to a particular release number like 20.04

Each host can decide which of these to use. Typically a host would use the base, -security and -updates but not -backports.
Its important to note that regardless of which set of these official repositories are enabled, the list of available software should
not change. Enabling -security or -updates will only provide potentially newer versions of the software but not add new software that
was not already present in the base.

I call these repositories with the same <releaseName> but different -<suffix> "Channels". By choosing which channels to use, use
decide how quickly you get new versions of your software but it does not affect which software you have available to install. Debian
and Ubuntu call these 'suite' which I personally find confusing.

Ubuntu's release strategy is to release a new major version every six months. The version number of the release is YY.MM where MM
is either 04 for April or 10 for October. Each version also has a codename (aka releaseName) which is an adjective and animal that
start with the letter after the one from the previous release. Every 2 years the April release is a long term support release (LTS).
The automatic update mechanism ('''apt update; apt upgrade''') will not upgrade to the new major release. Users have to specifically
choose to upgrade to the next major release and that process is heaver and takes longer and has the potential to change the workflow
that the user has grown accustomed to in the release they had been using.

This creates two tracks that users can follow for major version releases. One is to upgrade to each new release which means they will
do so on average each six months. The other is to only upgrade to LTS releases which means they will do so on average every two years.

The base repository is what is installed on distribution media. The base of a non-LTS release will typically never change. The base
of an LTS release will be updated infrequently and new distribution media created. Since a user will typically update the device
during or soon after the installation, it makes no functional difference whether the original base media or the newest one is used.
It seems that the main motivation of updating the base repository is so that first upgrade after installation is faster and so that
the system during installation can benefit from security patches.

The -security and -updates repositories are similar in concept but differ in the process used to include new versions and in the
frequency that new versions are released.

New versions of packages added to -security should fix security issues while changing as little else as is possible. This means that
there will typically not be any change to the way the users and systems interact with the software unless a method of interaction is
inherently the cause of the security issue.  When a critical security issue is found, the patch will be developed, tested and released
quickly as soon as possible.

New versions of packages added to -updates can contain new features and other improvements. They will absorb any security patches up
to the point of their release. The time frame of these releases may follow an arbitrary SDLC cycle.



### Repository Components: Grouping software together
Each debian-style repository is divided into components. Each component contains a mutually exclusive set of software. When a client
chooses to use a repository channel, the configuration line also must specify which components from that repository to use.

Ubuntu uses components to group software by its openness and who is responsible for maintaining its update channels.
* main : Canonical-supported free and open-source software
* universe : Community-supported free and open-source software
* restricted : proprietary drivers needed to support hardware
* multiverse : Software that is not totally free and/or open-source

Each of these components contain a different set of software. By choosing which to enable, a user affects which software is available
to install and update.

### Repository Architectures
Since packages often contain binary code compiled to run on a specific CPU architecture, different files have to be delivered to
clients based on the CPU they use.

Some packages consist only of portable scripts and other files that can run on any architecture as long as the appropriate runtimes
are present. These packages have historically been added to the file list in each supported architecture, however there is a change
in progress that allows them to be placed in a separate architecture that represents software that can run in any architecture.
Clients need to support that by know to request software from both their native architecture and the architecture-independent architecture.


### Folder Structure
On the server that hosts a debian-style repository, the file system that holds the repository is simply exposed to the Internet
with a web server using the automatic directory indexing feature. This means that the folder (aka directory) structure in the filesystem
will determine the URL path to access the files.

'''
dists/
 |+ focal/                   (<channelname/suitename>)
 |- focal-updates/           (<channelname/suitename>)
 |    |- main/               (component)
 |    |   |- binary-amd64/   (arch)                          triplet (focal-updates,main,amd64)
 |    |   |  '~ Packages.xz
 |    |   '+ binary-i386/    (arch)                          triplet (focal-updates,main,i386)
 |    |      '~ Packages.xz
 |    |+ universe/           (component)
 |    |+ restricted/         (component)
 |    ' InRelease     -.  
 |    '~ Release        | top level index file and signatures (InRelease has sig embedded and Release.gpg is the separate sig)  
 |    '~ Release.gpg   -'
 '+ pool/
'''
For consistency, the set of components below each channel/suite should be the same and the set of architectures below each component
should be the same but as long as the clients knows which complete triplets they can specify, they do not need to be consistent.

The dists/ folder subtree contains information about what software is available. Most of the files in this subtree are refered to as
'indexes'.
* Release: is the top level index file located in each channel folder. It contains fields that describe the identity of the channel
(aka suite), list of components and architectures in the channel and then a list of each specific index file in the channel along
with their hash. The Release file gets digitally signed so by including the hashes of the other indexes we do not have to also sign
each of those. Clients can confirm the integrity of any file in the channel by first confirming the Release file signature and then
confirming that the hash of each downloaded file matches the hash in the index file that lists it.
* Packages: is located at each complete triplet (i.e. in each architecture folder). It contains a paragraph for each deb file
available. Included in each paragraph is the path relative to the parent of the dists/ folder to the actual .deb file that contains
the software. It also contains the hash of the deb file so that the client can confirm its integrity after downloading it.

There can be are other files listed in the top level Release file too that provide for the optional mechanisms of
internationalization of language, more user friendly software centers and associating commands and files with the sowftware that
provides them.   

### Rectangualar Prism Summary
The three dimensions described above can be summarized like this. The top level unit is what I call a channel and what debian calls
a suit.  A URL address identifies a channel/suit hosted on some web server somewhere. The channel/suite has a Release file that describes
its contents -- which components and which architectures it has. Each component,architecture pair in the channel has a Packages file that
has a paragraph for each .deb package it contains that describes its attributes including the path to the .deb file in the pool folder
tree and its hash to verify its integrity.

The client configuration consists of a number of repository triplets (channel,component,arch) which brings in a finite set of deb
packages. The client can specify as many triplets as it wants. The contents of the triplets are logically combined to form a single
list of packages that are available to be installed. A .deb package name can exist in multiple triplets but only if they have
different version numbers. Version numbers can be compared so that as long as they are different, one is always greater and the
greater one is use as the install candidate by default.

Each distribution can use the concepts of channel and components as they see fit to implement a release strtegy and to segregate
software based on attributes that teh clients want to choose.  


## Feature structure
Debian-style repositories can provide the following features.
* base functionality of providing deb packages to be installed
* internationalization to support different languages
* associating shell commands with the packages that provide them (when you type a command that is not installed, bash may prompt you to install the package that provise it)
* associating files with the packages that provide them so that users can find out which package installed a file
* higher level app store support

The last one deserves a bit more explanation. Underlying the deb repository system is the notion of how software is split up into
deb packages.  Many deb packages provide library and other technical support to applications. deb packages can depend on the other
deb packages.  This means that of all the deb packages available, only a subset are of interest for the end user to install directly.
Also, modern app stores like itunes nad google play present screenshots and app specific icons and other assets to inform the user
better about the application they are considering installing. A system has been added to the debian-style repositories so that app
store like applications can present only the high level packages that users are interested in installing directly and provide images
and icons to aid in the presentation.

The base functionality is that the channel has a Release file which is signed for integrity which contains paths and hashes to
Packages files for each component,architecture pair. Each of those Packages files contain a paragraph for each contained .deb file
that includes the deb path, version number, hash for integrity, dependent debs and other attributes. This allows the basic function
to install a .deb package and all of its dependencies.

The Release file can optionally contain the paths and hashes to translation files for different languages.

The Release file can also optionally contain the paths and hashes to Content files that list all the files that each package will install so
that a user can query which package to install in order to get a particular file installed.

The Release file can also optionally contain the paths and hashes to Command files that list all the coomands that each package will install so
that a user can query which package to install in order to get a particular command installed.

The Release file can also optionally contain paths and hashes to Component and icon files that support better app store like functionality on
the client.
