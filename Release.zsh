# How AppRelease (https://github.com/Mx-Iris/AppRelease) ships LaunchpadAwakener: run `app-release all`.
# Every setting is described in AppRelease's README.
release_engine_version=1.0.0

release_workspace=LaunchpadAwakener.xcworkspace
release_scheme=LaunchpadAwakener
release_team_identifier=D5Q73692VW
# Signed with Developer ID while archiving, not only at export: the standalone app is zipped into the
# app's resources, where export cannot re-sign it, and the notary service looks inside that zip.
# The two validation flags are the ones RunScript.sh passes; without them xcodebuild refuses the
# packages' macros on a Mac where nobody has trusted them in Xcode.
release_archive_arguments=(
    -skipMacroValidation
    -skipPackagePluginValidation
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=Developer ID Application"
    DEVELOPMENT_TEAM=D5Q73692VW
    OTHER_CODE_SIGN_FLAGS=--timestamp
)
release_notary_keychain_profile=notarytool-password
release_publishers=(github-release)

# What the engine's checks do not cover: injection needs an arm64e slice in the daemon and the payload,
# both launchd property lists must start executables the app carries, and the standalone app must be in
# the zip the control panel installs it from.
launchpad_awakener_verify_contents() {
    local application_path=$1
    local binary_path architectures
    for binary_path in \
        "$application_path/Contents/Library/LaunchServices/LaunchpadAwakenerDaemon" \
        "$application_path/Contents/Resources/LaunchpadAwakenerPayload.framework/LaunchpadAwakenerPayload"; do
        [[ -f $binary_path ]] || app_release_fail "no ${binary_path:t} at $binary_path"
        architectures=$(lipo -archs "$binary_path")
        [[ " $architectures " == *" arm64e "* ]] ||
            app_release_fail "${binary_path:t} has no arm64e slice ($architectures), so injection into the Dock would fail"
        app_release_detail "${binary_path:t}: $architectures"
    done

    local -a property_list_paths=(
        "$application_path"/Contents/Library/LaunchDaemons/*.plist(N)
        "$application_path"/Contents/Library/LaunchAgents/*.plist(N)
    )
    (( ${#property_list_paths} == 2 )) ||
        app_release_fail "expected one launch daemon and one launch agent property list, found ${#property_list_paths}"
    local property_list_path bundle_program
    for property_list_path in "${property_list_paths[@]}"; do
        bundle_program=$(plutil -extract BundleProgram raw -o - "$property_list_path")
        [[ -x $application_path/$bundle_program ]] ||
            app_release_fail "${property_list_path:t} starts $bundle_program, which the app does not contain"
        app_release_detail "${property_list_path:t} -> $bundle_program"
    done

    local standalone_archive_path=$application_path/Contents/Resources/Launchpad.zip
    zipinfo -1 "$standalone_archive_path" Launchpad.app/Contents/MacOS/Launchpad > /dev/null 2>&1 ||
        app_release_fail "$standalone_archive_path does not hold Launchpad.app"
}

# Signed with this team's Developer ID and a secure timestamp, and executables with the hardened runtime:
# what the notary service asks of every piece of code it finds. The engine checks the app as a whole;
# the payload framework sits in Resources and the standalone app inside a zip, out of that check's reach.
launchpad_awakener_verify_signature() {
    local code_path=$1 requirement=${2:-}
    local details
    details=$(codesign --display --verbose=4 "$code_path" 2>&1) ||
        app_release_fail "${code_path:t} is not signed: $details"
    [[ $details == *"Authority=Developer ID Application: "*"($app_release_team_identifier)"* ]] ||
        app_release_fail "${code_path:t} is not signed with the Developer ID of team $app_release_team_identifier"
    [[ $details == *$'\nTimestamp='* ]] ||
        app_release_fail "${code_path:t} is signed without a secure timestamp"
    if [[ $requirement == hardened-runtime ]]; then
        [[ $details =~ 'flags=0x[0-9a-f]+\(([a-z-]+,)*runtime(,[a-z-]+)*\)' ]] ||
            app_release_fail "${code_path:t} is signed without the hardened runtime"
    fi
    app_release_detail "${code_path:t}: Developer ID ($app_release_team_identifier), timestamp${requirement:+, $requirement}"
}

release_verify_archive() {
    local archive_path=$1 application_path
    application_path=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$archive_path/Info.plist")
    launchpad_awakener_verify_contents "$archive_path/Products/$application_path"
}

release_verify_export() {
    local application_path=$1
    launchpad_awakener_verify_contents "$application_path"
    launchpad_awakener_verify_signature "$application_path/Contents/Library/LaunchServices/LaunchpadAwakenerDaemon" hardened-runtime
    launchpad_awakener_verify_signature "$application_path/Contents/Library/LoginItems/LaunchpadAwakenerTextInput.app" hardened-runtime
    launchpad_awakener_verify_signature "$application_path/Contents/Resources/LaunchpadAwakenerPayload.framework"

    local extraction_directory
    extraction_directory=$(mktemp -d "${TMPDIR:-/tmp}/LaunchpadAwakenerRelease.XXXXXX")
    ditto -x -k "$application_path/Contents/Resources/Launchpad.zip" "$extraction_directory"
    launchpad_awakener_verify_signature "$extraction_directory/Launchpad.app" hardened-runtime
    rm -rf "$extraction_directory"
}
