// flask Server
var SERVER_URL = "https://vmshop.int.xcalar.com:1224";
//var SERVER_URL = "https://komogorov.int.xcalar.com:1224";
var TEST_API_URL = SERVER_URL + "/flask/";

//  notify these users EVERY job, regardless what's put in the notify input
//var DEFAULT_NOTIFY = ['jolsen@xcalar.com'];
var DEFAULT_NOTIFY = ['jolsen@xcalar.com', 'abakshi@xcalar.com'];

// name of Jenkins job which will get triggered to build the VMs, when user
// submits main schedule form
var OVIRT_JENKINS_JOB = "OvirtToolBuilder";
var JOB_URL = "https://jenkins.int.xcalar.com/job/" + OVIRT_JENKINS_JOB;
var MAX_NUM_VMS = 5;
var DEFAULT_NUM_VMS = 1;
var MAX_RAM_VALUES = [8, 16, 32, 64]; // gb
var DEFAULT_RAM = [MAX_RAM_VALUES[2]];
var MAX_CORES = 8;
var DEFAULT_CORES = 4;

// boolean for if user is currently planning to install Xcalar on VMs
// gets set when user selects one of the installer type radio button
var WILL_INSTALL_XCALAR;

// map of RC build names to display in dropdown (keys),
// and the paths for each flavor of the build
// {'RC18': {'debug':<path>,'prod':<path>,..}
// gets popoulated after calling flask /get-rc-list api
// (will display the RC build names in RC dropdown, and path is what gets sent
// to the Jenkins job)
var RC_BUILD_MAP = {};

// dom ids, for Dom objects with HTML strings that should changed based on if
// user is requesting one, or multiple VMs (to accomidate sing. vs. plural grammar)
// 0: is what 'html' attr should be if only one VM, 1: is
// what 'html' attr should be if multiple VMs requested.
var SING_PLURAL_STRS = {
    'vm-basename-label': {
        0: "Please enter a name for your VM.",
        1: "Please enter a name for your VMs."
    },
    'install-type-none-label': {
        0: "I don't want to install Xcalar on this VM.",
        1: "I don't want to install Xcalar on these VMs."
    },
    'cores-label': {
        0: "Cores",
        1: "Cores (per VM)"
    },
    'ram-label': {
        0: "Ram",
        1: "Ram (per VM)"
    },
};

var $loginBlock;
var $scheduleBlock;

var $loginForm;
var $loginButton;
var $loginMsgDiv;
var $scheduleMsgDiv;

var $vmBasenameInput;

var $scheduleForm;
var $scheduleButton;

var JENKINS_USER;
var JENKINS_PASS;

// installer types, since it will be checked in multiple places.
// value should be the 'value' attr of the <input
var OWN = "own";
var STABLE = "latest-stable";
var RC = "get-rc";
var NO = "no-inst";

var $numVmsDropdown;
var $installerTypeRadioInputs;
var $userInstallerOptionSection;
var $userInstallerInput;
var $rcInstallerOptionSection; // should be the wrap container both the initially hidden dropdowns
// (installer dd + installer flavor dd)
// (installer flavor dd gets populated based on installer dd selection)
// if RC radio button selected, installer dd should always show.
// right now, they should always both show at the same time, but could be case
// where an installer has no flavor options so want to be able to hide that one still.
// so having them both in wrapper lets you just display everythign in that wrapper
// and can control within the wrapper what to show
var $rcInstallerDropdown; // the actual installer dd.
// the wrapper for this installer dd dont need to manipulate because always want it to show if the section containing it is showing
var $rcFlavorDropdownSection; // contained within rcInstallerOptionSection.  right now always show it
// if section containing it is shown, but maybe would change that if there's no flavor for the selected installer
var $rcFlavorDropdown; // the actual installer flavor dd
var $clusterCheckboxSection;
var $clusterCheckbox;
var $numRamDropdown;
var $numCoresDropdown;
var $emailListInput;

var userParam = 'user'; // param string
var passParam = "password";

var CODE_OK = 200;
var ERR_AUTH = 401;
var ERR_INTERNAL_SERVER_ERR = 500;


/**
 * initialize the inputs to their defaults
 */
function initializeFields() {
    // vmbasename: want to default to username but used needs to login first

    // installer type radio buttons: none selected (makes user pay attention and decide)

    // RC installer dropdown - default to first in list
}

var emails = {};

$( document ).ready(function() {
    $vmBasenameInput = $("#vm-basename");
    $emailListInput = $("#notify-list");
    $loginBlock = $("#login-block");
    $loginForm = $("#login-form");
    $loginButton = $("#login-button");
    $scheduleBlock = $("#vm-schedule-block");
    //$scheduleBlock = $("#schedule-block"); // why?@!?
    $scheduleForm = $("#schedule-form");
    $scheduleButton = $("#schedule-button");
    $loginMsgDiv = $("#login-msg");
    $scheduleMsgDiv = $("#schedule-msg");
    $userInstallerOptionSection = $("#my-installer-wrap");
    $userInstallerInput = $("#own-installer");
    $rcInstallerOptionSection = $("#rc-installer-wrap");
    $rcInstallerDropdown = $("#rc-installer");
    $rcFlavorDropdownSection = $("#rc-flavor-wrap");
    $rcFlavorDropdown = $("#rc-flavor");
    $numRamDropdown = $("#count-ram");
    $numCoresDropdown = $("#count-cores");
    $numVmsDropdown = $("#count-vms");
    $clusterCheckboxSection = $("#Q-form-cluster");
    $clusterCheckbox = $("#cluster-check");

    $installerTypeRadioInputs = $("#group1 input[type=radio]");

    // will get tooltips in DOM elements with 'tooltipped' class to show up
    // with slight delay (they will NOT show up at all if you don't have this afaik)
    $('.tooltipped').tooltip({delay: 50});

    // setup event handlers

    // if user selects a radio button for installer type,
    // hide/show child divs appropriately
    $installerTypeRadioInputs.change(function() {
        console.log("installer type changed in radio button");
        var selected = $(this).val();
        if (selected === OWN) {
            setupForOwnInstaller(true);
            setupForRCInstaller(false);
            setWillInstall(true);
        } else if (selected === STABLE) {
            setupForOwnInstaller(false);
            setupForRCInstaller(false);
            setWillInstall(true);
        } else if (selected === RC) {
            setupForOwnInstaller(false);
            setupForRCInstaller(true);
            setWillInstall(true);
        } else if (selected === NO) {
            setupForOwnInstaller(false);
            setupForRCInstaller(false);
            setWillInstall(false);
        } else {
            throw "Installer type could not be identifier (change)";
        }
    });

    // if user selects an RC, re-populate the build flavors for that RC re-bind
    $rcInstallerDropdown.change(function() {
        setFlavorDropdown()
        .then(function(res) {
            // initialize the materialize
            $('select').formSelect();
            $rcFlavorDropdownSection.show();
        });
    });

    // if user selects > 1 for num of VMs, unhide option for forming in to cluster
    $numVmsDropdown.change(function () {
        setNumVmsAction();
    });

    // event handlers for validation

    // validate hostname supplied.  will do this right away instead of waiting for submit.
    $vmBasenameInput.focusout(function() {
        console.log("focus out on vmbasename");
        validateVmbasenameInputField(); // checks if user has supplied the vmbasename and if so validates it and sets error messages
    });

    $emailListInput.focusout(function() {
        console.log("focus out on email list");
        // this method will return if everything is successful,
        // and will fail the div if anything fails
        getValidatedNotifyList();
    });

    // clear any errors if they change the field
    $emailListInput.on("keyup", function() {
        clearInputFieldErrorStatus($emailListInput);
    });

    // clear any errors if they change the field
    $vmBasenameInput.on("keyup", function() {
        clearInputFieldErrorStatus($vmBasenameInput);
    });

    // if user fills out own installer path,
    // clear out any existing errors.  This only gets validated on submit.
    // (but do not set it valid which will go green - just clear out invalid)
    $userInstallerInput.on('keyup', function() {
        clearInputFieldErrorStatus($userInstallerInput);
    });

    // try to validate own installer if supplied
    $userInstallerInput.focusout(function() {
        console.log("focus out on installer");
        validateUserInstallerInput();
    });

    $loginForm.submit(function (event) {
        event.preventDefault();
    });
    $scheduleForm.submit(function (event) {
        event.preventDefault();
    });

    $loginButton.click(tryLogin);
    $scheduleButton.click(function() {
        scheduleSubmit();
    });

    // dynamically set up things like dropdown menu options, etc.
    // make sure to bind materialize ONLY AFTER THIS
    populateObjects()
    .then(function(res) {
        // everything is ready!
        $loginBlock.show();
        //$scheduleBlock.show();
        // initialize the materialize
        $('select').formSelect();
    })
    .fail(function(err) {
        console.log("something went wrong in setup.. :(");
        $("#general-msg").addClass("msg-error");
        var contact_mail = "jolsen@xcalar.com";
        $("#general-msg").html('The VMShop can not be set up, sorry.  ' +
            'Please contact ' +
            '<a href="mailto:' + contact_mail + '?Subject=VMShop%20Server%20Down" target="_top">' +
            contact_mail + '</a> and send your ' +
            'javascript console log, if possible.  <br>' +
            'You can check if the server is down by visiting: ' +
            '<a href="' + TEST_API_URL + '" target="_blank">' + TEST_API_URL + '</a>' +
            "<br>(If it says 'Bad Gateway', then the server is down)");
        $("#general-msg").show();
    });
});

function validate() {
    // check for any fields with errors
    console.log("check for any error fields");
    var numItems = $('.invalid').length;
    if (numItems !== 0) {
        //alert("Please clear any errors!");
        return false;
    } else {
        return true;
        console.log("no invalid elements");
    }
}

/**
 * the schedule section is a form.  There are required attributes on several of the inputs.
 * if you try to submit the form and one of the required is not filled in, will automaticlaly
 * give a popup saying 'please fill out this field'.  On submit we have disabled the default event
 * and want to begin scheduling Jenkins job.
 */
function validateRequired() {
    var deferred = jQuery.Deferred();
    $('input,textarea,select').filter('[required]:visible').each(function() {
        if ( $(this).val() === '' ) {
            // get id
            var htmlId = $(this).attr('id');
            console.log("some field (" + htmlId + ") is blank");
            deferred.reject("a required field is blank");
        }
    });
    requiredRadios = ['install-type'];
    for (var requiredRadio of requiredRadios) {
        if (!$("input:radio[name='" + requiredRadio + "']").is(":checked")) {
            var failMsg = "rejecting because no selection on required radio buttons (" + requiredRadio + ")";
            console.log(failMsg);
            deferred.reject(failMsg);
        }
    }
    deferred.resolve("all required fields have something");
    return deferred.promise();
}

function populateObjects() {

    var deferred = jQuery.Deferred();

    // generate RAM dropdown options
    for (var i = 0; i < MAX_RAM_VALUES.length; i++) {
        $numRamDropdown.append($('<option></option>').val(MAX_RAM_VALUES[i]).html(MAX_RAM_VALUES[i] + " GB"))
        // set default
        $numRamDropdown.val(DEFAULT_RAM);
    }


    // generate CORES dropdown options
    for (var i = 1; i <= MAX_CORES; i++) {
        $numCoresDropdown.append($('<option></option>').val(i).html(i))
        // set default
        $numCoresDropdown.val(DEFAULT_CORES);
    }

    // generate options for number of VMs
    for (var i = 1; i <= MAX_NUM_VMS; i++) {
        $numVmsDropdown.append($('<option></option>').val(i).html(i))
        // set default
        $numVmsDropdown.val(DEFAULT_NUM_VMS);
    }

    // dropdown menu (initially hidden) w/ list of RC installers
    // this one requires an api call
    setRCList($rcInstallerDropdown)
    .then(function(res) {
        // set the default RC to most recent one

        // set the flavor dropdown based on that default, if possible
        return setFlavorDropdown(true, true);
    })
    .then(function(res) {
        deferred.resolve("everything set here");
    })
    .fail(function(error) {
        console.log("something went wrong setting rc list");
        deferred.reject(error);
    });

    return deferred.promise();

/**
    Promise.all([dynamicSetupPromise, staticSetupPromise]).then(function(values) {
    });
*/

}

/**
 * takes a jQuery object that should be a <select>,
 * and populates with names of RC installers dirs
 */
function setRCList($dropDown) {

    var deferred = jQuery.Deferred();
    // get list of RC builds
    //sendRequest("GET", SERVER_URL + "/flask/get-rc-list", {"regex": '.*1\.4.*'})
    // This api only accepts @POST, even if you don't want to pass any JSON data, keep it as @POST
    sendRequest("POST", SERVER_URL + "/flask/get-rc-list", {"regex": '.*1\.4.*'})
    .then(function(res) {
        console.log(res);
        if (res.hasOwnProperty("rclist")) {
            rcList = res.rclist;
            console.log("Populating rc dropdown");
            //RC_BUILD_MAP = res.rclist;
            var rcList = res.rclist;
            console.log(rcList);
            var commonErr = "one of the RC hashes returned by get-rc-list not in expected format";
            // it comes back from the server sorted
            for (var i = 0; i < rcList.length; i++) {
                var nextRcHash = rcList[i];
                var rcName;
                var buildFlavorsHash;
                if (nextRcHash.hasOwnProperty("name")) {
                    // name of the RC build
                    rcName = nextRcHash["name"];
                } else {
                    var nameErr = commonErr + " (no 'name' key)";
                    throw nameErr;
                    console.log(nameErr);
                    deferred.reject(nameErr);
                }
                if (nextRcHash.hasOwnProperty("flavors")) {
                    buildFlavorsHash = nextRcHash["flavors"];
                } else {
                    var flavorErr = commonErr = " (no 'flavor' key)";
                    throw flavorErr;
                    console.log(flavorErr);
                    deferred.reject(flavorErr);
                }
                // add in to dropdown, and also RC_BUILD_MAP
                RC_BUILD_MAP[rcName] = buildFlavorsHash;
                $dropDown.append($('<option></option>').val(rcName).html(rcName));

            }
/**
            var rc_keys = Object.keys(RC_BUILD_MAP);
            console.log("RC BUILD MAP::");
            console.log(RC_BUILD_MAP);
            for (var i = 0; i < rc_keys.length; i++) {
                console.log("add in : " + rc_keys[i]);
                $dropDown.append($('<option></option>').val(rc_keys[i]).html(rc_keys[i]));
            }
*/
        } else {
            throw "No RC list attribute";
        }
        // rebind
        $('select').formSelect();
        deferred.resolve("ok");
    })
    .fail(function(error) {
        console.log("Failed to get RC list data from server.  Error:");
        console.log(error);
        deferred.reject(error);
    });
    return deferred.promise();
}

function setFlavorDropdown(autoshow=false, rebind=true) {
    var deferred = jQuery.Deferred();


    // going to set the build flavors (prod, debug, etc.) based on what's
    // avaialble for that installer.
    // in case it's got the same options as what's currently there,
    // want to keep the current selection, so save that before populating
    var flavorSelected = $("option:selected", $rcFlavorDropdown).text();

    // sets the build flavor dropdown based on what's currently selected in the rc dropdown
    var rcSelected = $("option:selected", $rcInstallerDropdown).text();
    if (typeof rcSelected !== 'undefined') {
        // get the keys for that in the build mapping
        console.log("Setting RC flavor.  RC SELECTED: " + rcSelected);
        if (RC_BUILD_MAP.hasOwnProperty(rcSelected)) {
            // clear out what's currently there
            $rcFlavorDropdown.html("");
            var rcSelectedHash = RC_BUILD_MAP[rcSelected];
            // get the build types
            var buildTypeKeys = Object.keys(rcSelectedHash);
            for (var i = 0; i < buildTypeKeys.length; i++) {
                console.log("found build flavor: " + buildTypeKeys[i]);
                var $newOption = $('<option></option>').val(buildTypeKeys[i]).html(buildTypeKeys[i]);
                if (buildTypeKeys[i] === flavorSelected) {
                    // has the option that was currently selected; select this one by default
                    // so nothing changes for the user.
                    $newOption.prop('selected', true);
                }
                $rcFlavorDropdown.append($newOption);
                //$rcFlavorDropdown.append($('<option></option>').val(buildTypeKeys[i]).html(buildTypeKeys[i]));
            }
            if (rebind) {
                // initialize the materialize
                $('select').formSelect();
            }
            if (autoshow) {
                $rcFlavorDropdownSection.show();
            }
            deferred.resolve("ok");
        } else {
            deferred.reject("ERROR: No build map for rc selected: " + rcSelected + "!");
            throw "ERROR: There is no build map for rc selected: " + rcSelected + "!";
        }
    } else {
        deferred.resolve("nothing set yet; resolving");
    }
    return deferred.promise();
}

function setupForOwnInstaller(own=true) {
    if (own) {
        $userInstallerOptionSection.show();
        // set required property on the field for this
        $userInstallerInput.prop('required',true);
    } else {
        $userInstallerOptionSection.hide();
        // set required property on the field for this
        $userInstallerInput.prop('required',false);
    }
}

function setupForRCInstaller(use=true) {
    if (use) {
        $rcInstallerOptionSection.show();
    } else {
        $rcInstallerOptionSection.hide();
    }
}

function setWillInstall(install=false) {
    if (install) {
        WILL_INSTALL_XCALAR = true;
        if ($numVmsDropdown.val() > 1) {
            $clusterCheckboxSection.show();
        }
    } else {
        WILL_INSTALL_XCALAR = false;
        $clusterCheckboxSection.hide();
    }
}

// action to take if user changes selection for number of VMs.
// (depending on if there's one or > 1 VM requested, might hide
// some divs, and change grammar of some user messages.)
function setNumVmsAction() {
    var numVmsSelected = $("option:selected", $numVmsDropdown).val();
    if (numVmsSelected > 1) {
        change_str_cases(singular=false);
        if (WILL_INSTALL_XCALAR) {
            $clusterCheckboxSection.show();
        }
    } else {
        change_str_cases(singular=true);
        $clusterCheckboxSection.hide();
    }
}

// sets certain html str messages to user to have correct grammar
// regarding number of VMs in their current request
function change_str_cases(singular=true) {
    for (var el_id of Object.keys(SING_PLURAL_STRS)) {
        // change the html
        var $domObj = $("#" + el_id);
        if (singular) {
            $domObj.html(SING_PLURAL_STRS[el_id][0]);
        } else {
            $domObj.html(SING_PLURAL_STRS[el_id][1]);
        }
    }
}

function resetMsgDiv($msgDiv) {
    $msgDiv.html("");
    $msgDiv.removeClass("msg-error");
    $msgDiv.removeClass("msg-good");
}

function tryLogin() {
    console.log("try to log in");
    resetMsgDiv($loginMsgDiv);
    $user = $("#user");
    $p = $("#p");
    console.log("got user");
    if ($("#user").val()) {
        console.log("user available");
        var userVal = $user.val();
        // split on '@' in case they supplied their full xcalar email
        var strSplit = userVal.split("@");
        JENKINS_USER = strSplit[0];
        JENKINS_PASS = $p.val();
        sendRequest("POST", SERVER_URL + "/flask/login", {'user': JENKINS_USER, 'password': JENKINS_PASS})
        .then(function(res) {
            console.log("success");
            console.log(res);
            console.log("Correct login was supplied!  Let's make some VMs!");
            $loginBlock.hide();
            openSchedulePage();
        })
        .fail(function(res) {
            console.log("failure:");
            console.log(res);
            if (res.status === ERR_AUTH) {
                $user.val("");
                $p.val("");
                //$errDiv.html(res.responseText);
                $loginMsgDiv.addClass("msg-error");
                $loginMsgDiv.html("You've entered an invalid login/password");
            } else {
                $loginMsgDiv.addClass("msg-error");
                console.log("res status: " + res.status);
                $loginMsgDiv.html("This isn't an auth error; something else went wrong... see console logs for details");
            }
        });
    } else {
        console.log("user not available");
    }
}

/** /////////////////////////
 * methods around user installer
 */ /////////////////////////

/**
 * returns hash with data regarding currently selected installer:
 * {
 *    'type': <OWN|STABLE|NO|RC> (installer type selected)
 *    'path': <path to installer for selection>
 *    'url': <url for path>,
 *    'element': <jQuery input element, for the selected, which you'd want to fail if path doesn't validate>
 * }
 *
 * - if no installer type selected, returns undefined
 * - if installer type is selected, but it's selected NO (don't install), returns:
 *    {'type': NO} (nothing else in hash)
 * - if one of the other installer types taking input is selected, but no input yet given,
 */
function getInstallerData() {
    var els = {};
    console.log("Get Installer Elements");
    var installTypeSelected = getSelectedInstallerType();
    if (typeof installTypeSelected === 'undefined') {
        // they've not yet selected, let natural form error go through
        console.log("No installer type has been selected yet");
        return undefined;
    } else {
        var $installField;
        var rawInstallerPath;
        console.log("Determine type of install requested");
        if (installTypeSelected === OWN) {
            console.log("using own");
            $installField = $userInstallerInput;
            rawInstallerPath = $userInstallerInput.val();
            els['type'] = OWN;
        } else if (installTypeSelected === STABLE) {
            els['type'] = STABLE;
            rawInstallerPath = "/netstore/builds/byJob/BuildTrunk/xcalar-latest-installer-prod-match";
        } else if (installTypeSelected === RC) {
            console.log("using rc");
            $installField = $rcInstallerDropdown;
            var rcInstallerSelected = $("option:selected", $rcInstallerDropdown).text();
            var rcFlavorSelected = $("option:selected", $rcFlavorDropdown).text();
            rawInstallerPath = getRCInstallerPath(rcInstallerSelected, rcFlavorSelected);
            console.log("path: " + rawInstallerPath);
            els['type'] = RC;
        } else if (installTypeSelected === NO) {
            console.log("User won't installer Xcalar - installer verified by default");
            els['type'] = NO;
            return els;
        } else {
            // none of the expected options.
            throw "Installer elements can't be identified";
        }

        console.log("Install path found: " + rawInstallerPath);
        els['element'] = $installField;
        // if nothing, reject (could be they've selected but haven't filled in any of the fields that appeared based on their selection)
        if (typeof rawInstallerPath === 'undefined' || rawInstallerPath === "" ) {
            console.log("user didn't give an installer yet - should not trigger jenkins");
            return els;
        } else {
            var installerUrl = getUrlFromPath(rawInstallerPath);
            console.log("Install url found: " + installerUrl);
            els['path'] = rawInstallerPath;
            els['url'] = installerUrl;
        }
    }
    return els;
}

// returns String for installer type currently selected ('val' attr of the selected option)
function getSelectedInstallerType() {
    var $installerOptionSelected = getSelectedInstallerOption();
    return $installerOptionSelected.val();
}

// returns the jQuery element for the <option> currently selected for installer type
function getSelectedInstallerOption() {
    return $installerTypeRadioInputs.filter(":checked");
}

// returns an URL for an installer path (i.e., /netstore/here --> http://netstore/here)
function getUrlFromPath(path) {
    // make sure leading '/' on the path
    var installerPath;
    if (path.startsWith("/")) {
        console.log("installer path starts with '/'");
        installerPath = path;
    } else {
        installerPath = "/" + path;
    }

    // tack an http on this
    var installerUrl = "http:/" + installerPath;
    return installerUrl;
}

// for rc installer option:
// given an rc and build flavor, returns the path for that rc/build
// (uses RC_BUILD_MAP, which should be initialized when api call to get-rc is called,
// which happens on document setup)
//
function getRCInstallerPath(rcKey, flavorKey) {
    if (RC_BUILD_MAP.hasOwnProperty(rcKey)) {
        if (RC_BUILD_MAP[rcKey].hasOwnProperty(flavorKey)) {
            return RC_BUILD_MAP[rcKey][flavorKey];
        } else {
            console.log("error!  no " + rcKey + "/" + flavorKey + " combo! build map:");
            console.log(RC_BUILD_MAP);
            throw "There's a build map for rc key " + rcKey + " but not for flavor " + flavorKey;
        }
    } else {
        throw "No key in build map for " + rcKey + "!";
    }
}

/**
 * Validates user installer input, if they have selected
 * to use own installer and have submitted data in the field.
 */
function validateUserInstallerInput() {
    var deferred = jQuery.Deferred();

    var installData = getInstallerData();
    if (typeof installData === 'undefined') {
        deferred.resolve("No install data; nothing to validate");
    } else {
        if (installData.hasOwnProperty('type')) {
            var installType = installData['type'];
            if (installType === OWN && installData.hasOwnProperty('url')) {
                if (installData.hasOwnProperty("element")) {
                    fieldValidateInstallerData(installData['url'], installData['element'])
                    .then(function(res) {
                        console.log("user installer validates!");
                        deferred.resolve("user install checks out!");
                    })
                    .fail(function(err) {
                        console.log("user installer didn't validate :(");
                        deferred.reject(err);
                    });
                } else {
                    throw "No jQuery element given back from getInstallerData; script issue";
                }
            } else {
                deferred.resolve("User installer isn't selected or not yet provided; nothing to validate");
            }
        } else {
            throw "user has selected install type, but no 'type' was returned";
        }
    }
    return deferred.promise();
}

// Verify an installer URL is valid.
// if not, error out the element passed in
function fieldValidateInstallerData(url, errEl) {
    if (typeof errEl === 'undefined') {
        throw "errEl to fieldValidateInstallerData undefined. " +
            " (Did you call getInstallerData - if so, was the " +
            " 'element' key missing from the returned hash?)";
    }
    var deferred = jQuery.Deferred();
    console.log("call api to validate installer url");
    isInstallerUrlValid(url)
    .then(function(res) {
        // everything ok. clear out any errors
        setFieldOk(errEl);
        deferred.resolve("installer URL is a-ok!");
    })
    .fail(function(err) {
        // there's an error - get it and set here
        console.log("did not pass validation of installer val");
        console.log("call set field error with " + err);
        //$("#help-test").attr("data-error", res);
        setFieldErr(errEl, err);
        deferred.reject("installer url wasn't valid :(");
    });
    return deferred.promise();
}

// pass an URL to validate; rejects if server can not access or has error,
// resolves if server can access the URL
function isInstallerUrlValid(url) {
    console.log("call api to validate installer url");
    var deferred = jQuery.Deferred();
    sendRequest("POST", SERVER_URL + "/flask/validate/url", {"url": url})
    .then(function(res) {
        console.log("returned from api call successfully");
        // returns a 'result' json key
       if (res.hasOwnProperty("result")) {
            var resMsg = res.result;
            if (resMsg === true) {
                console.log("installer url ok");
                deferred.resolve("ok");
            } else {
                // get the error
                console.log("installer url invalid");
                deferred.reject(resMsg);
            }
        } else {
            var errMsg = "isInstallerUrlValid: missing 'result' attr from api return";
            console.log(errMsg);
            deferred.reject(errMsg);
        }
    })
    .fail(function(err) {
        var rejectString = getRejectMessage(err);
        var errMsg = "Something went wrong when checking if installer URL is valid! " + rejectString;
        console.log(errMsg);
        deferred.reject(errMsg);
    });
    return deferred.promise();
}

/** ////////////////////////////
 * methods around vmbasename
 */ ////////////////////////////

// calls Server to pass prospective hostname to see if it's valid
function isHostnameValid(hostname) {
    console.log("prepare to call api to validate hostname");
    var deferred = jQuery.Deferred();
    sendRequest("POST", SERVER_URL + "/flask/validate/hostname", {"hostname": hostname})
    .then(function(res) {
        console.log("returned from api call successfully");
        // returns a 'result' json key
       if (res.hasOwnProperty("result")) {
            var resMsg = res.result;
            if (resMsg === true) {
                console.log("hostname ok");
                deferred.resolve("ok");
            } else {
                // get the error
                console.log("hostname invalid");
                deferred.reject(resMsg);
            }
        } else {
            var errMsg = "validatehostname: missing 'result' attr from api return";
            console.log(errMsg);
            deferred.reject(errMsg);
        }
    })
    .fail(function(err) {
        var rejectString = getRejectMessage(err);
        var errMsg = "Something went wrong when checking if hostname is valid! " + rejectString;
        console.log(errMsg);
        deferred.reject(errMsg);
    });
    return deferred.promise();
}

/**
 * returns current value user has input for the 'vm hostname' field
 */
function getVmbasename() {
    return $vmBasenameInput.val();
}

function validateVmbasenameInputField() {
    var deferred = jQuery.Deferred();
    // get the value
    var currVmname = getVmbasename();
    console.log("HOSTNAME: " + currVmname + ", validate it");
    if (currVmname) {
        console.log("got curr vmanme: " + currVmname);
        isHostnameValid(currVmname)
        .then(function(res) {
            // everything ok. clear out any errors
            setFieldOk($vmBasenameInput);
            deferred.resolve("hostame is a-ok!");
        })
        .fail(function(err) {
            // there's an error - get it and set here
            console.log("did not pass validation of hostname val");
            console.log("call set field error with " + err);
            //$("#help-test").attr("data-error", res);
            setFieldErr($vmBasenameInput, err);
            deferred.reject("hostanme wasn't valid :(");
        });
    } else {
        console.log("User hasn't yet supplied anything for the hostname field");
        deferred.resolve("user hasn't supplied hostname yet");
    }
    return deferred.promise();
}

function getEmailList() {
    var emailList = $emailListInput.val();
    // collapse whitespace
    return emailList.replace(/\s/g,'');
}

/**
 * returns a String, which is comma separated list of users the Jenkins
 * job should notify upon job completion.  This is a list of both, what
 * user has supplied in the email-notify input, as well as a set of DEFAULT_NOTIFY
 * users which should always get notified.
 * Dupes are handled, and email addresses are validated.
 * If any of the emails fail validation, the input element is failed with proper message.
 */
function getValidatedNotifyList() {
    // dont just get the val, need to replace whitespace
    var emailList = $emailListInput.val();
    if (typeof emailList === 'undefined' || emailList.trim() === "") {
        console.log("nothing here to validate");
        return;
    }
    //split on comma
    var emailSplit = emailList.split(",");
    var invalidEmails = [];
    var notifyHash = {};
    for (var emailAdd of emailSplit) {
        if (isEmailValid(emailAdd)) {
            notifyHash[emailAdd] = "";
        } else {
            invalidEmails.push(emailAdd);
            console.log("in here");
        }
    }
    if (invalidEmails.length > 0) {
        setFieldErr($emailListInput, "Error on entries: " + invalidEmails.join(", "));
        return false;
    } else  {
        console.log("never get here");
        console.log("set field ok");
        setFieldOk($emailListInput);
        // add in the default mails to it
        for (var defaultEmailUser of DEFAULT_NOTIFY) {
            notifyHash[defaultEmailUser] = "";
        }
        // get keys and string them comma
        var notifyKeys = Object.keys(notifyHash);
        var fullNotifyList = notifyKeys.join(",");
        return fullNotifyList;
    }
}

function isEmailValid(emailAdd) {
    console.log("email: [" + emailAdd + "]");
    if (/^\w+([\.-]?\w+)*@\w+([\.-]?\w+)*(\.\w{2,3})+$/.test(emailAdd)) {
        console.log("email: " + emailAdd + " is valid");
        return true;
      } else {
        console.log("email : " + emailAdd + " is invalid");
        return false;
    }
}

/** /////////////////////////////////////
 * for handling input validation:
 * set error/success status on field
 */ /////////////////////////////////////

function isFieldErrored($inputField) {
    if ($inputField.hasClass("invalid")) {
        return true;
    } else {
        return false;
    }
}

function setFieldErr($inputField, errMsg) {
    // right now alert - don't know how to do anything else yet...
    $inputField.removeClass("valid");
    console.log("setFieldErr: add invalid class");
    $inputField.addClass("invalid");
    console.log("now alert");
    var $fieldsErrHelper = getValidationMsgElementForInputField($inputField);
    $fieldsErrHelper.attr("data-error", errMsg);
    //alert(errMsg);
    // disable submit
    $scheduleButton.prop("disabled", true);
}

function setFieldOk($inputField) {
    $inputField.removeClass("invalid");
    $inputField.addClass("valid");
}

/**
 * clear out valid and invalid classes on an input field.
 * this will take away the pass and fail styling on the element.
 */
function clearInputFieldErrorStatus($inputField) {
    $inputField.removeClass("invalid");
    $inputField.removeClass("valid");

    // if submit button had been disabled and now there's no other error,s
    // re-enable it
    if ($scheduleButton.is(":disabled") && validate()) {
        $scheduleButton.prop("disabled", false);
    }
}

/**
 * get the label for a given field, which is where you put the descriptor of the field.
 * It only works if you have 'for=<name of field id>' as an attribute.
 */
function getLabelElementForInputField($inputField) {
    // get id of the field
    var fieldId = $inputField.attr("id");
    var label = $('label[for="' + fieldId + '"]');
    return label;
}

/**
 * return the <span> element attached to a given field, which the error helper text
 * should be set in, in materialize, to display an error for that field.
 * This is going to work because we are adding 'for="<fieldname>", in the html,
 * in each of these span elements.  If you don't have that 'for=' it won't work.
 * example:
 *       <input type="text" id="own-installer" />
 *         <label for="own-installer">Installer path</label> // this is the field label
 *         <span class="helper-text" for="own-installer" data-error="wrong" data-success=""></span> // this is where you set error/pass messages in materialize.  notice the 'for' attribute.
 *
 */
function getValidationMsgElementForInputField($inputField) {
    var fieldId = $inputField.attr("id");
    console.log("field id: " + fieldId);
    // it'll be a class
    var $errObj = $('.helper-text[for="' + fieldId + '"]');
    console.log($errObj);
    return $errObj;
}

/** /////////////////////////////
 * SUBMITTING THE VM REQUEST FORM
 */ ////////////////////////////

/**
 * action to be performed upon submitting schedule form:
 *
 * 1. make sure all params needed for Jenkins job are present and valid values
 * 2. if so, trigger the Jenkins job with all such params.
 *  Failure/success is updated in each of the scenarios as want to handle them differently.
 * (if you change the html it's going to prevent the form errors from alerting so in some cases don't want to do anything)
 */
function scheduleSubmit() {

    var deferred = jQuery.Deferred();
    // Get hash of params required for triggerJenkins,
    // while validating.  will update divs on failures
    getValidatedParamsForJenkinsJob() // handles its own failure case.
    .then(function(res) {
        // res should be the exact hash 'triggerJenkins' needs
        // updates divs on failures.
        return triggerJenkinsAndUpdateMessages(res);
    })
    .then(function(res) {
        // everything worked!
        // disable the button now
        $scheduleButton.prop("disabled", true);
        deferred.resolve(res);
    })
    .fail(function(err) {
        // don't do anything - they have handles their own failure cases.
        deferred.reject(err);
    });
    return deferred.promise();
}

/**
 * return true if all variables required by Jenkins job are present,
 * and throws error if not.
 * Note - it does NOT validate the params - only checks they are actually defined, and
 * not empty where required. (i.e., if noXcalar is False, make sure installer is defined, else doesn't matter
 */
function checkForMissingJenkinsParams(vmbasename="", num="", ram="", cores="", installer="", noXcalar="", formCluster="", emailList="") {

    var mustHave = [vmbasename, num, ram, cores, emailList];
    for (var avar of mustHave) {
        console.log("check avar: "+ avar);
        if (isEmptyOrUndefined(avar)) {
            var errMsg = "one of the required variables is undefined or empty";
            console.log(errMsg);
            throw errMsg;
        }
    }
    // vals that must be true/false
    var bools = [noXcalar, formCluster];
    for (var bool of bools) {
        if (typeof bool !== "boolean") {
            var errMsg = "one of the boolean variables is not a boolean";
            console.log(errMsg);
            throw errMsg;
        }
    }
    // check installer if its needed
    if (noXcalar === false) {
        // must have an installer
        if (isEmptyOrUndefined(installer)) {
            var errMsg = "not noxcalar, but installer is undefined or empty";
            console.log(errMsg);
            throw errMsg;
        }
    }
    return true;
}

/**
 * Resolves w/ the hash required by 'triggerJenkins'
 * function (the function which will trigger the Ovirt Jenkins job.),
 * while validating all params (i.e., hostname, installer URL, etc.)
 * If any params fail to validate, or fails to find required params, rejects
 * THIS SHOULD HANDLE UPDATING ERR/SUCCESS MESSAGES AS REQUIRED.
 * (We want to handle err case differenlty here than on triggerJenkins)
 */
function getValidatedParamsForJenkinsJob() {
    var deferred = jQuery.Deferred();

    // get all the params needed for Jenkins job from user fields,
    // to put in the returned hash
    var vmbasename = getVmbasename();
    var numVms = $("option:selected", $numVmsDropdown).text();
    var numRams = $("option:selected", $numRamDropdown).val(); // text will have GB in it
    var numCores = $("option:selected", $numCoresDropdown).text();
    var installerElements = getInstallerData();
    if (typeof installerElements === 'undefined') {
        console.log("install type hasn't been selected yet; don't continue");
        deferred.reject("install type hasn't been selected yet");
    } else {
    var installerUrl = installerElements['url'];
    var installerElementToFail = installerElements['element'];
    var installType = installerElements['type'];
    var noXcalar = false;
    if (installType === NO) {
    // if no install option was selected, this function will return undefined
    //if (typeof installerUrl === 'undefined') {
        noXcalar = true;
    }
    var formCluster = $clusterCheckbox.prop('checked'); // returns True/False boolean if checked or not
    var emailList = getEmailList();

    try {
        // throws err if any of the params/param combinations are missing
        checkForMissingJenkinsParams(vmbasename=vmbasename, num=numVms,
            ram=numRams, cores=numCores, installer=installerUrl,
            noXcalar=noXcalar, formCluster=formCluster, emailList=emailList);

        // validate email list (will send back array of all, including default emails)
        var validatedNotifyList = getValidatedNotifyList();
        if (validatedNotifyList) {
            // validate individual dynamic input fields
            // ** call wrapper functions of these which fail the divs if validation
            // fails, since rejects go to a common fail block and need to update
            // different divs depending on what's being validated
            validateVmbasenameInputField()
            .then(function(res) {
                // if there is an URL to validate
                if (typeof installerUrl !== 'undefined' && installerUrl !== "") {
                    // 'element' should always be present
                    return fieldValidateInstallerData(installerUrl, installerElementToFail);
                } else {
                    return dummyPass();
                }
            })
            .then(function(res) {
                // great everything is here!
                // send it off
                // remember - the point of this function ,is to return EXACTLY THE HASH
                // that 'triggerJenkins' function consumes.  So if you change any params here, you would need to update that function too!
                // see function doc of 'triggerJenkins' to see what param keys should be
                var jenkins_job = {
                    'VMBASENAME': vmbasename,
                    'COUNT': numVms,
                    'RPM_INSTALLER_URL': installerUrl,
                    'RAM': numRams,
                    'CORES': numCores,
                    'no_xcalar': noXcalar,
                    'form_cluster': formCluster,
                    'ovirtuser': JENKINS_USER, // Jenkins and Ovirt login are same, use the Jenkins login they provided
                    'ovirtpass': JENKINS_PASS,
                    'NOTIFY_LIST': validatedNotifyList
                };
                deferred.resolve(jenkins_job);
            })
            .fail(function(err) {
                // right now do nothing to DOM on failure - just console.  Else we'll suppress form errors.
                console.log("Failed to get param hash for 'triggerJenkins': Reason:");
                console.log(err);
                deferred.reject(err);
            });
        } else {
            console.log("failed to validate email list");
            deferred.reject("falied to validate email list");
        }
    } catch (e) {
        // there was an issue - some of the params must not be filled in yet.
        console.log(e);
        deferred.reject(e);
    };
    }
    return deferred.promise();
}

/**
 * triggers Jenkins job, and directly updates DOM with failure/success messages, etc..
 * @params: the hash of params required by 'triggerJenkins' function.
 * (See documentation of 'triggerJenkins' for format of params)
 * NOTE - It's suggested you call ' getValidatedParamsForJenkinsJob' before calling this,
 * so you don't unintentionally update dom with issues of user not having filled in
 * params, which would suppress normal form errors
 */
function triggerJenkinsAndUpdateMessages(params) {
    var deferred = jQuery.Deferred();
    triggerJenkins(params)
    //dummyPass()
    .then(function(res) {
        // not doing anything yet
        alert("Your job has been scheduled! " +
            "All users listed in the 'Notify upon completion' field will " +
            "receive an email once the job completes, with the details " +
            "of any newly created VMs. The process should take about " +
            "30 minutes.  Jenkins job URL: " + JOB_URL);
        $scheduleMsgDiv.html("Cool, I think it worked.  go check <a href='" + JOB_URL + "' target='_blank'>" + JOB_URL + "</a> . job should take about 30 mins.");
        $scheduleMsgDiv.addClass("msg-good");
        console.log("success");
        console.log(res);
        deferred.resolve("ok");
    })
    .fail(function(err) {
        // don't want to go any futher.  Because if the issue was undefined/empty params,
        // that is an issue with the js - as it should have been caught in the
        //  getValidatedParamsForJenkinsJob and never got this far.  SO don't worry
        // about updating msg div and suppressing form empty errors
        console.log("Hit failure when calling 'triggerJenkins'");
        console.log(err);
        var rejectMessage = getRejectMessage(err);
        var errMsg = "Failed trying to process VM request.  " +
            "Reason detected (possibly from server): " + rejectMessage;
        console.log(errMsg);
        $scheduleMsgDiv.html(errMsg);
        $scheduleMsgDiv.addClass("msg-error");
        deferred.reject(errMsg);
    });
    return deferred.promise();
}

/**
 * Triggers Ovirt Jenkins job with given params.
 * @params: a hash with all required params for the Jenkins job itself.
 * keys must be the same name as the params in the Jenkins job, that is
 * how we'll know what to pass to the job
 * params are NOT validated in this method.  Whatever you send, will get sent to Jenkins
 * {
 *        'VMBASENAME': <vm basename>,
 *        'COUNT': <num vms>,
 *        'RPM_INSTALLER_URL': <url of installer>,
 *        'RAM': <ram per node>,
 *        'CORES': <cores per node>,
 *        'no_xcalar': <boolean install xcalar>,
 *        'form_cluster': <boolean form cluster>,
 *        'ovirtuser': <Ovirt username>, **
 *        'ovirtpass': <Ovirt password>,  **
 *        'NOTIFY_LIST': <comma list of emails>,
 * }
 *        ** note: these Ovirt credentials taht the job requires are same as Jenkins
 *           as its all ldap
 */
function triggerJenkins(params) {
    var deferred = jQuery.Deferred();

    // make sure they passed params
    if (typeof params === 'undefined') {
        deferred.reject("params was not supplied to triggerJenkins");
    } else {
        /**
         * make sure all the params were properly supplied to this function,
         * before triggering Jenkins job.  Could mean there's a logic error here
         * and we're out of sync with  getValidatedParamsForJenkinsJob
         */
        var paramsReqForJob = ['VMBASENAME', 'COUNT', 'RPM_INSTALLER_URL',
                'RAM', 'CORES', 'no_xcalar', 'form_cluster',
                'ovirtuser', 'ovirtpass', 'NOTIFY_LIST'];
        var jobParams = {};
        var missingParams = [];
        for (var reqParam of paramsReqForJob) {
            if (params.hasOwnProperty(reqParam)) {
                jobParams[reqParam] = params[reqParam];
            } else {
                missingParams.push(reqParam);
            }
        }
        if (missingParams.length > 0) {
            deferred.reject("Can't schedule Jenkins job - missing params for hash:" + missingParams);
        } else {
            // all params are here.
            // params for the POST to the server api
            var apiParams = {
                'user': JENKINS_USER,
                'password': JENKINS_PASS,
                'job-params': jobParams
            }
            //return dummyPass()
            sendRequest("POST", SERVER_URL + "/flask/trigger/" + OVIRT_JENKINS_JOB, apiParams)
            .then(function(res) {
                deferred.resolve("Job triggered");
            })
            .fail(function(res) {
                deferred.reject(res);
            });
        }
    }
    return deferred.promise();
}

// returns True/False if a variable is empty or undefined
function isEmptyOrUndefined(avar) {
    if (typeof avar === "undefined" || avar === "") {
        return true;
    }
    return false;
}

function dummyPass() {
    var deferred = jQuery.Deferred();
    deferred.resolve("ok");
    return deferred.promise();
}

function openSchedulePage() {
    $scheduleBlock.show();
    // set user name as placeholder in the vmbasename field
    //$vmBasenameInput.val(JENKINS_USER);  // should you set html or text? look in to this!
    $vmBasenameInput.attr("placeholder", JENKINS_USER);
    $emailListInput.attr("placeholder", JENKINS_USER + "@xcalar.com");
}

// takes a JSON obj, or JSON string, and returns a copy
// with any "password" field blurred out
function blurPassword(data) {
    // returns a string of * the length of the string
    function starString(str) {
        var plen = jsonCopy.password.length;
        var star = "*";
        var stars = "";
        for (var i = 0; i < plen; i++) {
            stars += star;
        }
        return stars
    }

    var jsonCopy = {};
    if (typeof(data) == "string") { // data is JSON string
        try {
            jsonCopy = JSON.parse(data);
        } catch (e) {
            console.log("ERROR: wasn't json - nothing will be blurred");
            return data;
        }
    } else { // data we're assuming is already JSON
        // deep copy else its going to modify the original json
        jsonCopy = JSON.parse(JSON.stringify(data));
    }

    // swap out the passwords
    if (jsonCopy.hasOwnProperty('password')) {
        jsonCopy['password'] = starString(jsonCopy['password']);
    }
    if (jsonCopy.hasOwnProperty('job-params') && jsonCopy['job-params'].hasOwnProperty('ovirtpass')) {
        jsonCopy['job-params']['ovirtpass'] = starString(jsonCopy['job-params']['ovirtpass']);
    }

    return JSON.stringify(jsonCopy);
}

/**
 * converts a rejected promise from sendRequest to a useful String.
 * If can't find a specific error, stringifies the json
 */
function getRejectMessage(res) {
    if (typeof res === 'string' || res instanceof String) {
        console.log("reject message is already a string! " +
            "(Should not happen; sendRequest likely out of sync): " + res);
        return res;
    } else {
        // this key would be set in sendRequest - NOT the actual API.
        // sendRequest handles API return JSOn and creates a new JSON
        if (res.hasOwnProperty("error")) {
            console.log("has error property");
            return res.error;
        } else {
            console.log("none of the common vars... just return this...");
            return JSON.stringify(res);
        }
    }
}

/**
 * make ajax call
 * @action: type of call (GET, POST, DELETE, etc)
 * @url: endpoint valid for the server
 * @jsonToSend: stringified json (for example in POST request)
 * @timeout: timeout in milliseconds after which to reject.
 *  defualt is no timeout. (from jQuery docs: 0 means no timeout)
 *
 *  example:
 *  sendRequest("GET", "/hostSettings");
 *  sendRequest("POST", "/install", JSON.stringify({'installStep': 'xdpce'}));
 */
function sendRequest(action, url, data={}, timeout=0) {
    var deferred = jQuery.Deferred();
    //deferred.resolve();
    //return deferred.promise();
    console.log("send " + url);
    console.log(blurPassword(data));
    var dataJsonStr = JSON.stringify(data);
    try {
        var ajaxCallConfig = {
            method: action,
            url: url,
            data: dataJsonStr,
            contentType: "application/json",
            success: function (ret) {
                console.log("server call success");
                deferred.resolve(ret);
            },
            error: function (xhr, textStatus, errorThrown) {
                console.log("xhr:");
                console.log(xhr);
                console.log("err thrown");
                console.log(errorThrown);
                console.log("error stringified");
                console.log(JSON.stringify(errorThrown));
                console.log("Error on Ajax call to " + url + "; json " +
                    blurPassword(dataJsonStr) +
                    ";  text status: " + textStatus +
                    "; error thrown: " + JSON.stringify(xhr));
                console.log(xhr.statusCode());
                var requestReject = {"status": xhr.status};
                if (xhr.status === 502) {
                    requestReject["error"] = "Connection to Server could not be established";
                } else {
                    if (xhr.responseJSON) {
                        // under this case, server sent the response and set
                        // the status code
                        requestReject["responseText"] = xhr.responseText;
                        requestReject["responseJson"] = xhr.responseJSON;
                        // 'error' key commonly in our APIs, if it's there, add in as field to bubble up
                        if (xhr.responseJSON.hasOwnProperty("error")) {
                            console.log("setting error");
                            requestReject["error"] = xhr.responseJSON.error;
                        }
                        //deferred.reject(xhr.responseJSON);
                    } else {
                        // under this case, the error status is not set by
                        // server, it may due to other reasons
                        requestReject = "The server returned an internal Server Error";
                    }
                }
                deferred.reject(requestReject);
            }
        };
        jQuery.ajax(ajaxCallConfig);
    } catch (e) {
        deferred.reject({
            "status": httpStatus.InternalServerError,
            "error": "Caught exception making ajax call to " +
                url + ": " + e
        });
    }
    return deferred.promise();
}


