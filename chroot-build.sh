#!/bin/bash

<<COMMENT
This script allows building linux binary packages in pristine chroot environment.
Typical chroot build configuration file should look like this:

#!/usr/bin/env chroot-build.sh
pkg_name "my-project"
pkg_version "0.0.1"
pkg_description "My cool project"
pkg_directories usr etc
pkg_platform ubuntu 14
  pkg_replaces my-other-project
  pkg_conflicts my-other-project
  build_deps make gcc libev-devel
  runtime_deps libev
  build_script "make install"
  pkg_scripts pkg/*.sh

How this works.

Script defines simple DSL for chroot build configuration files.
Configuration file should reside in git repository. When you run
configuration file build script is generated. If you run configuration
file with --local option this script will:
    - unpack precompiled chroot image if it is present or create new one from scratch
    - install all latest updates
    - install build dependencies
    - copy the whole git repository (excluding .git and build directories) to /tmp of chroot
    - cd /tmp/git_root/chroot-build/conf/dir and run build script
    - create package based on new files in chroot that appeared after build.
    - when chroot-build would complete you would find package in ./build/platform directory, chroot files would be removed.
    - if build would fail you would have chroot environment to debug issue.

If you run configuration file with -–server server.name option the whole git directory (excluding .git and build directories)
is sent to remote server. After that generated script is run like in local build above. In the end of the build ./build
directory with created packages would be copied to machine that initiated build.

Configuration file is essentially bash script, so you can use variables, loops etc
COMMENT

set -u -e

CHROOT_BUILD_DIR="/var/chroot-build"
CHROOT_BUILD_CACHE=${CHROOT_BUILD_DIR}/.cache

# urls used to download centos-release rpm (to install base system)
declare -A release_base=(
    [5]=http://mirror.centos.org/centos/5/os/x86_64/CentOS/
    [6]=http://mirror.centos.org/centos/6/os/x86_64/Packages/
    [7]=http://mirror.centos.org/centos/7/os/x86_64/Packages/
)

# urls used to download epel rpm (to enable extended package repositories)
declare -A epel_base=(
    [5]=http://dl.fedoraproject.org/pub/epel/5/x86_64/
    [6]=http://dl.fedoraproject.org/pub/epel/6/x86_64/
    [7]=http://dl.fedoraproject.org/pub/epel/7/x86_64/e/
)

declare -A ubuntu_codenames=(
    [10]=lucid
    [12]=precise
    [14]=trusty
    [16]=xenial
)

declare -A platform_data=()

# this array contains all platforms supported by this build
all_platforms=()

# DSL definitions start

# sets package name
# TODO add check that name doesn't contain invalid symbols
pkg_name() {
    _pkg_name=$1
}

# sets package version
# TODO add check that version is ok
pkg_version() {
    _pkg_version=$1
}

# sets package description
pkg_description() {
    _pkg_description=$1
}

# sets list of directories where package files are being installed
# arguments: space separated list of directories without leading slash
pkg_directories() {
    _pkg_directories=$@
}

# sets list of packages this package replaces
# since packages on different distributions can have different names
# this should be set in the platform context
pkg_replaces() {
    local pkg _pkg_replaces=""
    [ -z "${_pkg_replaces:-}" ] && echo "ERROR: pkg_replaces should be used in pkg_platform context" && exit 1
    for pkg in $@; do _pkg_replaces+="--replaces $pkg "; done
    platform_data["${_pkg_platform}_pkg_replaces"]=$_pkg_replaces
}

# sets list of packages this package conflicts with
# since packages on different distributions can have different names
# this should be set in the platform context
pkg_conflicts() {
    local pkg _pkg_conflicts=""
    [ -z "${_pkg_platform:-}" ] && echo "ERROR: pkg_conflicts should be used in pkg_platform context" && exit 1
    for pkg in $@; do _pkg_conflicts+="--conflicts $pkg "; done
    platform_data["${_pkg_platform}_pkg_conflicts"]=$_pkg_conflicts
}

# starts setting platform parameters
# arguments: 1 - os name, 2 - os version
pkg_platform() {
    _pkg_platform=$1$2
    all_platforms+=($_pkg_platform)
    platform_data["${_pkg_platform}_version"]=$2
}

# build time dependencies (e.g. make, gcc, development libraries etc)
build_deps() {
    platform_data["${_pkg_platform}_build_deps"]=$@
}

# runtime dependencies (e.g. non development libraries)
runtime_deps() {
    platform_data["${_pkg_platform}_runtime_deps"]=$@
}

# script to build and install package (e.g. "make && make install")
# this script works in chroot environment
# script can be provided as string argument or as here document
build_script() {
    local script=${1:-}
    [ -z "${_pkg_platform:-}" ] && echo "ERROR: build_script should be used in pkg_platform context" && exit 1
    [ -z "$script" ] && {
        [ -t 0 ] && echo "ERROR: build_script has no input data" && exit 1
        script=$(cat)
    }
    platform_data["${_pkg_platform}_build_script"]=$script
}

# sets package scripts, that should be run during installation/update/removal.
# arguments: space separated list of scripts (e.g. ./pkg/before-install.sh ./pkg/before-remove.sh)
# wildcards can be used(e.g. ./pkg/*.sh). Important! The valid script names are before-install.sh, after-install.sh, before-remove.sh, after-remove.sh.
pkg_scripts() {
    local file option s=()
    [ -z "${_pkg_platform:-}" ] && echo "ERROR: pkg_scripts should be used in pkg_platform context" && exit 1
    for file ; do
        [ -r "$file" ] && {
            option=$(basename $file|sed -e 's/[.][^.]*$//')
            s+=("--${option} $file")
        }
    done
    platform_data["${_pkg_platform}_pkg_scripts"]="$(echo ${s[@]})"
}

# DSL definitions end

# let's source configuration file
. $1

# git repo root on local filesystem
git_root_dir=$(git rev-parse --show-toplevel)
# git_root_dir can change for remote builds, let's preserve it in separate variable
local_git_root_dir=$git_root_dir
git_project_name=$(basename $git_root_dir)
# current directory in git repo
git_cur_dir=$(pwd|sed -e "s@$git_root_dir@@")
# build would be run in ./build directory
build_dir=$(pwd)/build
# do we want to install chroot-build runtime dependencies automatically?
install_deps=false
# in preview mode we just generate build script and exit
preview=false

# this array is populated by --platform options
target_platforms=()

# this function checks if platform provided by --platform option is supported
check_platform() {
    local p
    [ "${#all_platforms[@]}" != "0" ] && {
        for p in ${all_platforms[@]}; do
            [ "$p" == "$1" ] && return 0
        done
    }
    echo "ERROR: Platform $1 not supported"
    exit 1
}

# remote server name for remote build
# localhost for local builds
# if empty - error
build_server=""
# -x flag for bash enabled by --debug option
bash_x=""
# by default buid can't process with uncommitted changes
# this can be overridden by --ignore-uncommitted option
check_uncommited=true

# let's parse cli options
# at the very least you should provide --local or --server
while shift ; do
    case ${1:-} in
        --platform)
            check_platform $2
            target_platforms+=($2)
            shift
            ;;
        --server)
            build_server=$2
            shift
            ;;
        --local)
            build_server="localhost"
            ;;
        --install-dependencies)
            install_deps=true
            ;;
        --debug)
            set -x
            bash_x="-x"
            ;;
        --preview)
            preview=true
            ;;
        --ignore-uncommitted)
            check_uncommited=false
            ;;
    esac
done

# let's check that mandatory global parameters were set
for param in pkg_name pkg_version pkg_description pkg_directories ; do
    var=_$param
    [ -z "${!var:-}" ] && echo "ERROR: mandatory $param is not set" && exit 1
done

# build can't be run with uncommitted changes (unless we use --ignore-uncommitted option)
$check_uncommited && [ -n "$(git status -s)" ] && {
    echo "ERROR: Remote build requires all changes to be committed."
    echo "Please run \"git add --all && git commit -a -v\" and try again."
    echo "If you really want to build uncommitted changes (this is not recommended) please use --ignore-uncommitted option."
    exit 1
}

# let's check if we have platforms defined
[ "${#all_platforms[@]}" == "0" ] && echo "ERROR: no build platforms defined" && exit 1

# if platforms were not specified via command line let's build for all supported platforms
[ "${#target_platforms[@]}" == "0" ] && target_platforms=(${all_platforms[@]})

# have we got --local or --server ?
[ -z "$build_server" ] && {
    echo "ERROR: Please specify --local for local build or --server your.build.server for remote build"
    exit 1
}

# cmd variable holds generated build script
cmd="set -u -e
type fpm >/dev/null 2>&1 || {
    if $install_deps ; then
        sudo apt-get install -y ruby1.9.3
        sudo gem install fpm
    else
        echo ERROR: fpm not installed. Please specify --install-dependencies
        echo You also can run manually following commands:
        echo sudo apt-get install -y ruby1.9.3
        echo sudo gem install fpm
        exit 1
    fi
}
"
# for remote build we need to change git_root_dir and build_dir
[ "$build_server" != "localhost" ] && {
    git_root_dir=${CHROOT_BUILD_DIR}/${USER}/${git_project_name}
    build_dir=${git_root_dir}/${git_cur_dir}/build
}

# this function generates build code for single platform
# TODO should be split into several functions
prepare_platform() {
    local version=${platform_data[${1}_version]} platform=$1
    [ -z "${platform_data[${platform}_build_script]:-}" ] && echo "ERROR: build script not defined for platform $platform" && exit 1
    chroot_dir=$build_dir/$platform/
    fpm_options="${platform_data[${platform}_pkg_scripts]:-} --description \"$_pkg_description\" ${platform_data[${platform}_pkg_replaces]:-} ${platform_data[${platform}_pkg_conflicts]:-} "
    # runtime dependencies
    for d in ${platform_data[${platform}_runtime_deps]:-}; do
        fpm_options+="-d $d "
    done
    cmd+="
sudo rm -rf $chroot_dir
mkdir -p $chroot_dir"
    case $1 in
        centos*)
            release_rpm=$(curl -s ${release_base[$version]}|sed -e 's/<[^>]*>/\n/g'|grep ^centos-release-$version)
            epel_rpm=$(curl -s ${epel_base[$version]}|sed -e 's/<[^>]*>/\n/g'|grep ^epel-release-$version)
            release_rpm_url=${release_base[$version]}$release_rpm
            epel_rpm_url=${epel_base[$version]}$epel_rpm
            release_rpm_path=${CHROOT_BUILD_CACHE}/$release_rpm
            epel_rpm_path=${CHROOT_BUILD_CACHE}/$epel_rpm
            pkg_type=rpm
            cmd+="
if [[ -n \"$CHROOT_BUILD_CACHE\" && -r ${CHROOT_BUILD_CACHE}/${platform}.tgz ]] ; then
    sudo tar xzf ${CHROOT_BUILD_CACHE}/${platform}.tgz -C $build_dir
    echo 'yum -y --nogpgcheck update && yum clean all'|sudo chroot ${chroot_dir} bash -s
else
    [ -r $release_rpm_path ] || sudo wget -q -O $release_rpm_path $release_rpm_url
    [ -r $epel_rpm_path ] || sudo wget -q -O $epel_rpm_path $epel_rpm_url
    sudo mkdir -p ${chroot_dir}/{var/lib/rpm,etc,opt,dev}
    sudo cp /etc/resolv.conf ${chroot_dir}/etc
    for p in rpm yum; do
        type \$p >/dev/null 2>&1 || {
            if $install_deps ; then
                sudo apt-get install -y \$p
            else
                echo ERROR: \$p not installed. Please specify --install-dependencies
                echo You also can run manually following command:
                echo sudo apt-get install -y \$p
                exit 1
            fi
        }
    done
    sudo rpm --root $chroot_dir --initdb
    sudo rpm -ivh --force-debian --nodeps --root $chroot_dir $release_rpm_path
    sudo rpm -ivh --force-debian --nodeps --root $chroot_dir $epel_rpm_path
    sudo yum -y --nogpgcheck --installroot=${chroot_dir} install bash yum python-hashlib
    cp $release_rpm_path ${chroot_dir}/tmp/
    echo 'mknod /dev/urandom c 1 9 && rpm --nodeps -i /tmp/${release_rpm}'|sudo chroot ${chroot_dir} bash -s
    sudo rm ${chroot_dir}/tmp/${release_rpm}
    echo 'yum -y --nogpgcheck update && yum clean all'|sudo chroot ${chroot_dir} bash -s
    if [ -n \"$CHROOT_BUILD_CACHE\" ] ; then
        sudo mkdir -p $CHROOT_BUILD_CACHE
        sudo tar czf ${CHROOT_BUILD_CACHE}/${platform}.tgz.\$\$ -C $build_dir $platform
        sudo mv ${CHROOT_BUILD_CACHE}/${platform}.tgz.\$\$ ${CHROOT_BUILD_CACHE}/${platform}.tgz
    fi
fi
sudo chroot ${chroot_dir} yum install -y ${platform_data[${platform}_build_deps]:-}"
            ;;
        ubuntu*)
            pkg_type=deb
            codename=${ubuntu_codenames[$version]}
            cmd+="
if [[ -n \"$CHROOT_BUILD_CACHE\" && -r ${CHROOT_BUILD_CACHE}/${platform}.tgz ]] ; then
    sudo tar xzf ${CHROOT_BUILD_CACHE}/${platform}.tgz -C $build_dir
    echo 'apt-get update && apt-get -y dist-upgrade && apt-get autoremove -y && apt-get autoclean'|sudo chroot ${chroot_dir} bash -s
else
    type debootstrap >/dev/null 2>&1 || {
        if $install_deps ; then
            sudo apt-get install -y debootstrap
        else
            echo ERROR: debootstrap not installed. Please specify --install-dependencies
            echo You also can run manually following command:
            echo sudo apt-get install -y debootstrap
            exit 1
        fi
    }
    sudo debootstrap --variant=buildd --verbose ${codename} ${chroot_dir}
    echo deb http://us.archive.ubuntu.com/ubuntu/ ${codename} universe | sudo tee -a ${chroot_dir}/etc/apt/sources.list
    echo 'apt-get update && apt-get -y dist-upgrade && apt-get autoremove -y && apt-get autoclean'|sudo chroot ${chroot_dir} bash -s
    if [ -n \"$CHROOT_BUILD_CACHE\" ] ; then
        sudo mkdir -p $CHROOT_BUILD_CACHE
        sudo tar czf ${CHROOT_BUILD_CACHE}/${platform}.tgz.\$\$ -C $build_dir $platform
        sudo mv ${CHROOT_BUILD_CACHE}/${platform}.tgz.\$\$ ${CHROOT_BUILD_CACHE}/${platform}.tgz
    fi
fi
sudo chroot ${chroot_dir} apt-get install -y ${platform_data[${platform}_build_deps]:-}"
            ;;
    esac
    cmd+="
for dir in $_pkg_directories; do sudo find ${chroot_dir}\${dir} -type f -o -type l; done|sort >$build_dir/${platform}.list
mkdir $chroot_dir/tmp/$git_project_name
tar czf - -C $git_root_dir --exclude .git --exclude build .|tar xzf - -C $chroot_dir/tmp/$git_project_name
cat << 'EOF_$platform' | sudo chroot ${chroot_dir} bash -s $bash_x
set -u -e
cd /tmp/$git_project_name/$git_cur_dir
${platform_data[${_pkg_platform}_build_script]}
EOF_$platform
comm -13 $build_dir/${platform}.list <(for dir in $_pkg_directories; do sudo find ${chroot_dir}\${dir} -type f -o -type l; done|sort)|sed -e s@$chroot_dir@@ >$build_dir/${platform}.fpm.list
fpm $fpm_options --epoch 1 --${pkg_type}-user root --${pkg_type}-group root --workdir ${build_dir} -s dir -t ${pkg_type} -v ${_pkg_version} -n ${_pkg_name} -C ${chroot_dir} --inputs $build_dir/${platform}.fpm.list
rm $build_dir/*.list
sudo rm -rf ${chroot_dir}*
sudo chmod 0777 $chroot_dir
mv ${_pkg_name}*${pkg_type} $chroot_dir
"
}

# loop through platforms, generate build code
for p in ${target_platforms[@]} ; do
    prepare_platform $p
done

# create build script
echo "$cmd" >generated-chroot-build-$$.sh

$preview && exit

if [ "$build_server" != "localhost" ] ; then
    tar czf - -C $local_git_root_dir --exclude=.git --exclude build . | ssh $build_server "set -u -e
        [ -d \"$CHROOT_BUILD_DIR\" ] || {
            sudo mkdir -p $CHROOT_BUILD_CACHE
            sudo chmod 1777 $CHROOT_BUILD_DIR
        }
        sudo rm -rf $git_root_dir
        mkdir -p $git_root_dir
        cd $git_root_dir
        tar xzf -
        cd ${git_root_dir}/${git_cur_dir}
        bash $bash_x ./generated-chroot-build-$$.sh"
    scp -r ${build_server}:${git_root_dir}/${git_cur_dir}/build .
else
    bash $bash_x generated-chroot-build-$$.sh
fi
# in case of unsuccessful builds there may be left over scripts
# since we are here this means success, let's delete all remaining build scripts
rm generated-chroot-build-*.sh

