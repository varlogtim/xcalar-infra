#!/bin/bash

set -e

cert=/tmp/XcalarInc_CA_Combined_$$.crt

cat > $cert <<'EOF'
-----BEGIN CERTIFICATE-----
MIIFeDCCA2CgAwIBAgIJAM262Y1LG61KMA0GCSqGSIb3DQEBCwUAMFgxCzAJBgNV
BAYTAlVTMQswCQYDVQQIEwJDQTERMA8GA1UEBxMIU2FuIEpvc2UxFTATBgNVBAoT
DFhjYWxhciwgSW5jLjESMBAGA1UEAxMJWGNhbGFyIENBMB4XDTE2MDIyODIwMzky
OFoXDTI2MDIyNTIwMzkyOFowWDELMAkGA1UEBhMCVVMxCzAJBgNVBAgTAkNBMREw
DwYDVQQHEwhTYW4gSm9zZTEVMBMGA1UEChMMWGNhbGFyLCBJbmMuMRIwEAYDVQQD
EwlYY2FsYXIgQ0EwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC9eLni
PvfVTv3PbcNpHkjsCC40cHkmk9ujjg39RTDX/kBA7Xev4uyVp3AJOIQdZQ9/QSFw
1iaJhximEkIzpGpdRecgwWPWz+sD4puSc8xPRFSqgsYN4xu4giX4H962B007xToX
ce6jybrUVMSv3x539ySX0LKVMxcer2DMzkC7b18Zs7d3XhT7F31hTIOO0aH+P/5O
4UjoWaVxGLBx5v/jB+ptlnRFrRsqEbENB8YaerYr+AryEJupRH/KMOHEXK6WIGXG
tjZOkvUd5O1kH3/dK+ndz7y0lvcKIEe3xtuKWo50dcygxCGutS5envw/LnpevovP
M0Q0GWk0OnhamfpQbjq2OkS9yOmE9dW/n32Gb8V0o09o3dQlYTkUYYwoceOOkLQs
wCX269CvbfOJjXMcb3L5/9AeoLe+tLBNHAqZ8OSgI6tZ+h4/GxNvuLIeejfaeafU
tlCNWavWs1CiuHrXtgz+DfU0NY4+MFl38jOQ1asCG5tdNBJSnc42hds8pBM75WmA
l5zwNTmtkQ2Hpxf0SsdWC+6fBtauJLu+0cwHvzPQq6yD5Ffb20XhT5+3GUUuhILN
FsporM/5BAx2wYPmiiJhSi/Q5lPcAF3VGM/STFZd7aiDvJjvryrZBR+xJnBqV2oe
jvp3o1MADFb8GRRM/3zf/+i3s5CaY6chhY/gMQIDAQABo0UwQzASBgNVHRMBAf8E
CDAGAQH/AgEBMA4GA1UdDwEB/wQEAwIBRjAdBgNVHQ4EFgQU04eXSTv26Oey5+qj
nTRknEmeb2kwDQYJKoZIhvcNAQELBQADggIBALxQF8BQCXVQWFBb+huW1STXosm0
rGq4kdCSncIvsLgtIc5JUBO7pxLUD7LBcsN1MRpWQJJ1W9YMlsbZ9OLwD8LdAqGb
GYfxdO/rufhHfTIbpWrAgUj5WJOxd64hV/IOPAnRBHewRibSGPuh9IzGmuzsU3sE
oiyPjeKlOq8H3hVSSXY2sWF72ym/pleOGanoDP0w1XuN+qf/iCGv19870OsMT2Nn
AGeZlk5gB0KwJ8dY/5+AdvyDGA0SUwr4HVQovdM7zsc/9S8yj6o3WPvsbwD8sKOB
0Zc7FOcgP6herHgz++VFG90NjXl03fIa3uJ172fS498GL33U6N7svVAIBke8kozu
FgtyXHFat2sxNl5nUM9azux5pGF75thRPH8rjYcqqv3gYB6EpHhutMff6W5+GHGN
P7EZBieimoTkoW4WlytDjI75iY/n1uNtGpqhiX5HIXkn1RRrCsngqvxh+ZsLq3JK
r2IPvhbUns9OcyrSlbf1P9iubTH4sJTn+0CKFLpTujHqyoZKoBKdF6uGT0sJfgab
ecuetWihv1zXqb3rAvTeA0Rq45zE+wNaql9eaY59+/6CAk0VPHJ8lRX41v+0rBFh
u3JEFtQdbAHA2hVb1lWyqVghMS2xacA00O96iWFuJAyvyGN3Fl0w2Da13nG9lLbp
644FMKheiX/xw+EY
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIGHTCCBAWgAwIBAgIBATANBgkqhkiG9w0BAQsFADBYMQswCQYDVQQGEwJVUzEL
MAkGA1UECBMCQ0ExETAPBgNVBAcTCFNhbiBKb3NlMRUwEwYDVQQKEwxYY2FsYXIs
IEluYy4xEjAQBgNVBAMTCVhjYWxhciBDQTAeFw0xNjAyMjgyMDM5MzRaFw0yNjAy
MjUyMDM5MzRaMFgxEjAQBgNVBAMTCVhjYWxhciBDQTELMAkGA1UEBhMCVVMxETAP
BgNVBAcTCFNhbiBKb3NlMRUwEwYDVQQKEwxYY2FsYXIsIEluYy4xCzAJBgNVBAgT
AkNBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAwwfAM307U7GswqdZ
QhAfPE4GfLF5pM8a8FdjqECpF9TCi+9s4G9Ctf+h8fB3Q8bnLn0AOLZ2n1Ae5jDh
qdhzFgaF/9Mlru6f+onG9SOYXF5z4bjt7e3EGtYAj0wZFaAQ/DI9QSSZ0zqsqk9H
qo0cYfcKduKkuRNKR0ejVfb9WroeunAkv2FFRoqQFaUQ5CoHXDSAHJt/6Mw2D+AH
DZ/6ivj0GzWKDM7CImFkQC9aVwsS5MTfwkEPS0Lff94lQoHB0Jva8it40Q2GUxc3
vYTurqypx3xG02laKn5pVIRRoT7SzmIu0w0oy8JjmbhaNA3Mr1Rm7nK2LNGCgD9H
kXmR0JrVdMiDJm1qZyC1DS7YCYNnhCiGKSElwx+grW/9KU6qvYa78J3Buc3rF7GE
O+XkCFbrVNTVGK4TbqQ0/T3UVMlpIn0i8hLHS314tPBWFbONQ3OfTdh7lbB+hEbX
uvB7e94t6Qvps3vZQsPqzxyQX6vcnuzANvF+zAfWXYSDxPshnxZo4R8B6CF13ON2
LFUa10d2wLefwRYrMbZMQY4AVpcqVPVZhWNLfzCYLfn6tt/6yS1pUWFGJa4ATv7s
hNBPfItvplQV24EXv4vcVVvvLnAL1iRruMIlBiBrYDUCSwhRcXpjIkBWMvU8I3E2
xYOs8cYoJ4Gw9eXsUA2D0ztCB7MCAwEAAaOB8TCB7jCBiQYDVR0jBIGBMH+AFNOH
l0k79ujnsufqo500ZJxJnm9poVykWjBYMQswCQYDVQQGEwJVUzELMAkGA1UECBMC
Q0ExETAPBgNVBAcTCFNhbiBKb3NlMRUwEwYDVQQKEwxYY2FsYXIsIEluYy4xEjAQ
BgNVBAMTCVhjYWxhciBDQYIJAM262Y1LG61KMBIGA1UdEwEB/wQIMAYBAf8CAQAw
HQYDVR0lBBYwFAYIKwYBBQUHAwIGCCsGAQUFBwMBMA4GA1UdDwEB/wQEAwIBRjAd
BgNVHQ4EFgQUFJwcgWkxSQCxTE5c7hr9iXf9KFEwDQYJKoZIhvcNAQELBQADggIB
AH0X1YHMArfIDo4f2yFEU7nQiXLv0M6zlcHNDoyb0GSUW9V2Xr+ipneoiszvxDPP
VAIHMdk6CeeDigHjccphHCPGL8Zjw1KHCaFVeT7zvLVkcio9y737vBUTT3Wx7qco
FqkryaCgmi6qhBnGdVsoTTncN/2lehxH1+rEjzB8LmTFojMbJBHLuOviuQE/+ZVr
2Vak2W8tX+3SCo0wVO+YOq/Q1rgqOMz5Lr+cPJnqimyZy13Fg+n/Kf+EWA0NHmMM
YI9SSKnVpSBcFYGO8b9TEQXC2lx+76LeyV/Fturtv6RwyAA118QWaXxfXu0dXM7F
B7QhwgzgLUBOaf7wNBPmVVpORN5xtJ2omV7yCVAuzjF6UvXZXfNumRkzKkKL2ffF
rltEkrTYNhavlAEBdibKy2d2XkUENxhCYEGFsxc+jGXAhHOwPA4Wjp5vsZJ7ay/N
dyx2MadBIYfWG2jrfoy/a6dvrxNNL16nGrRBhVUQ6+3GZeHY38Bmn8gw+LeiDXqp
5kc4QQQA0mhCzIM74BGs991fEUT7zdFXrV/bXvh9650yq3Upq8qwgwt53vYEGbtH
KkGZIrPx5jqmi2IxH1pH8GcMqbmYNn9sfw5IK2vCVtR6byScYprYk5Hl/yCPztNI
CnOy6nEzNHDYA3RQOIstT8LR9V+cvy4tGqJmlarOjGsT
-----END CERTIFICATE-----
EOF

uname_s="$(uname -s | sed -e 's/-.*$//g')"
set +e
if [ `id -u` -ne 0 ]; then
    sudo="$(type sudo 2>/dev/null | awk '{print $3}')"
    if [ "$sudo" = "" ]; then
        echo "This script needs to be run as root or have sudo installed" >&2
        exit 1
    fi
else
    sudo=
fi

if [ "$uname_s" = "Darwin" ]; then
	$sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $cert
	rc=$?
elif [ "$uname_s" = "Linux" ]; then
	if [ -r /etc/os-release ]; then
		. /etc/os-release
		case "$ID_LIKE" in
			debian)
			$sudo mkdir -p /usr/local/share/ca-certificates && \
			$sudo cp $cert /usr/local/share/ca-certificates/XcalarInc_CA_Combined.crt && \
			$sudo DEBIAN_FRONTEND=noninteractive update-ca-certificates
			rc=$?
			;;

			rhel*)
			$sudo update-ca-trust force-enable && \
			$sudo mkdir -p /etc/pki/ca-trust/source/anchors && \
			$sudo cp $cert /etc/pki/ca-trust/source/anchors/XcalarInc_CA_Combined.crt && \
			$sudo update-ca-trust extract
			rc=$?
			;;

			*)
			echo "ERROR: Unknown distro $NAME" >&2
			cat /etc/os-release >&2
			rc=3
			;;
		esac
	else
		echo "ERROR: Unsupported linux distro" >&2
		rc=2
	fi
elif [ "$uname_s" = "CYGWIN_NT" ] || [ "$uname_s" = "MSYS_NT" ]; then
	certutil -addstore "Root" "$(cygpath -wa $cert)"
	rc=$?
else
	echo "ERROR: Unknown OS: $uname_s" >&2
	rc=4
fi

if [ "$rc" = "" ]; then
	echo "ERROR: \$rc was never set" >&2
	rc=5
fi

if [ $rc -eq 0 ]; then
    if type openssl >/dev/null 2>&1; then
        openssl x509 -noout -text -in $cert | egrep -v '^\s+[0-9a-f][0-9a-f]:' >&2
    fi
	echo "Successfully installed the Xcalar CA certificate" >&2
	rm -f $cert
else
	echo "ERROR($rc): Failed to install the Xcalar CA certificate in $cert" >&2
fi
exit $rc
