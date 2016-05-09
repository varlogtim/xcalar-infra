# Xcalar-Infra

    mkdir -p $HOME/p
    git clone git@git:/gitrepos/xcalar-infra.git $HOME/p/xcalar-infra
    echo 'XLIDIR=$HOME/p/xcalar-infra' | tee -a $HOME/.bashrc
    source $HOME/.bashrc
    cd $XLIDIR
    git review -s

## repo

### apt

Steps when adding a deb pkg to the repo. First download the existing repo.

    export REPREPRO_BASE_DIR=/var/tmp/repo/apt/ubuntu
    gsutil -m rsync -c -d -R gs://repo.xcalar.net/apt/ubuntu/ $REPREPRO_BASE_DIR/

Now sign and add the new .deb

    DEB=/tmp/newdebs/libfoo_1.0-1_amd64.deb
    RELEASE=trusty
    dpkg-sig --sign builder -k F7515781 $DEB
    dpkg-sig --verify $DEB
    reprepro --ask-passphrase -Vb $REPREPRO_BASE_DIR includedeb $RELEASE $DEB

Do a dry run upload to GS

    gsutil -m rsync -n -c -d -R $REPREPRO_BASE_DIR/ gs://repo.xcalar.net/apt/ubuntu/

If you're happy with the results, run the same command without the `-n`. BE VERY CAREFUL of typos. This will
delete remote files so the directories match your local `$REPREPRO_BASE_DIR`.

    gsutil -m rsync -c -d -R $REPREPRO_BASE_DIR/ gs://repo.xcalar.net/apt/ubuntu/


