import os
import subprocess
import sys

# bash lib with functions used by this python script
# it is in <infra>/bin
# will be calling that shell script directly;
# make sure <infra>/bin is in system path of machine running this file, else will not work
INFRA_HELPER_SCRIPT='infra-sh-lib'
# chars that are disallowed in VM names
ILLEGAL_VMNAME_CHARS = ['.', '_']
# for param validation:
# protected search keywords in Ovirt GUI to disallow as VM names
# (vms_service.list api will fail if one of these words is supplied as the identifier,
# potentially mangling any automated search features if vms can have these names; so don't allow)
PROTECTED_KEYWORDS = ['cluster', 'host', 'fdqn', 'name']

'''
Checks if url can be supplied to curl; returns True or False
'''
def can_curl(url):
    '''
    calls 'check_url' func in bash helper lib, <INFRA>/bin/infra-sh-lib
    will check if url can be curled without downloading.
    you must source the file to call it directly
    '''
    bash_cmd = "bash -c 'source {}; check_url {}'".format(INFRA_HELPER_SCRIPT, url)
    print(bash_cmd)
    try:
        subprocess.check_call(bash_cmd, shell=True)
        return True
    except subprocess.CalledProcessError as e:
        return False

'''
Validation of VM params

call these functions with a prospective VM param;
if there's an issue a ValueError Exception will be raised
with a message indicating the nature of the error
'''

def validate_hostname(hostname):

    # validate name is all lower case, does not begin with any of
    # the Ovirt protected keywords,
    # and contains no chars that will cause issues if its part of hostname
    if (any(filter(str.isupper, hostname)) or
        any(illegal_char in hostname for illegal_char in ILLEGAL_VMNAME_CHARS)):
        raise ValueError("VM's basename must be all "
            "lower case letters, and may not contain any of "
            "the following chars: {}\n".format(" ".join(ILLEGAL_VMNAME_CHARS)))

        '''
        if the basename begins with one of Ovirt's search refining keywords
        (a string you can type in the GUI's search field to refine a search, ex. 'cluster', 'host')
        then the vms_service.list api will not work.
        this leads to confusing results which are not immediately obvious what's going on
        ensure prospective hostname does not begin with any of these words
        '''
        for ovirtSearchFilter in PROTECTED_KEYWORDS:
            if hostname.startswith(ovirtSearchFilter):
                raise ValueError("VM's basename can not begin with "
                    "any of the values: {} (These are protected keywords "
                    "in Ovirt)".format(PROTECTED_KEYWORDS))

'''
ensure URL can be curl'd on the local machine,
and doesn't appear as gui or userinstaller
'''
def validate_installer_url(installer_url):

    # make sure they have given the regular RPM installer, not userinstaller
    filename = os.path.basename(installer_url)
    if 'gui' in filename or 'userinstaller' in filename:
        raise ValueError("RPM installer required; this looks like a "
            "gui installer or userinstaller")

    # make sure can curl
    if not can_curl(installer_url):
        raise ValueError("Can not curl this installer URL.  "
            "Should be an URL for an RPM installer, in curl format.\n"
            "(If you know the <path> to the installer on netstore, "
            " then the URL to supply would be: http://netstore/<path>")
