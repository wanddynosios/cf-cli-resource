#shellcheck shell=bash

set -euo pipefail

export TMPDIR=$SHELLSPEC_TMPBASE
export CF_HOME=$(mktemp -d "$TMPDIR/.cf.XXXXXX")

BASE_DIR=$SHELLSPEC_PROJECT_ROOT
FIXTURE=$SHELLSPEC_SPECDIR/fixture

DEFAULT_CF_CLI_VERSION=6

spec_helper_configure() {
  import 'support/json_matcher'

  source 'resource/lib/cf-functions.sh'
  source 'resource/lib/util.sh'

  error_and_exit() {
    echo "$1" >&3
    exit 1
  }

  # Dependency checks
  (( "${BASH_VERSINFO[0]}" >= 4 )) || error_and_exit "[ERROR] bash v4 or higher is required (found version $BASH_VERSION)"
  command -v jq >/dev/null || error_and_exit "[ERROR] unable to locate jq binary (https://stedolan.github.io/jq/)"
  command -v yq >/dev/null || error_and_exit "[ERROR] unable to locate yq binary (https://github.com/mikefarah/yq)"
  [[ "$(yq --version)" != *"version v4"* ]] && error_and_exit "[ERROR] yq v4 is required (found $(yq --version))"

  # Negation helper function
  not() {
    ! "$@"
  }

  # Executes command capturing status and all output (stdout and stderr).
  # If command fails then output is echoed and failure status code is returned.
  quiet() {
    local output=
    if ! output=$("$@" 2>&1); then
      local status=${PIPESTATUS[0]}
      echo "[ERROR] $output"
      exit $status
    fi
  }

  load_fixture() {
    local fixture=${1:?fixture null or not set}

    if [ ! -d "$FIXTURE/$fixture" ]; then
      echo "[ERROR] Fixture not found: $FIXTURE/$fixture" >&2
      exit 1
    fi

    cd $(mktemp -d "$TMPDIR/$fixture.XXXXXX")
    cp -r "$FIXTURE/$fixture/." .

    pwd
  }

  get_env_var() {
    local name=${1:?environment variable name null or not set}
    local default_value=${2:-}
    if [ -z "${!name:-}" ]; then
      if [ -n "$default_value" ]; then
        echo "$default_value"
      else
        exit 1
      fi
    else
      echo "${!name}"
    fi
  }

  get_source_config() {
    local org=${1:-}
    local space=${2:-}

    local cf_api cf_username cf_password cf_cli_version
    cf_api=$(get_env_var "CCR_CF_API") || error_and_exit "[ERROR] required env var not set: CCR_CF_API"
    cf_username=$(get_env_var "CCR_CF_USERNAME") || error_and_exit "[ERROR] required env var not set: CCR_CF_USERNAME"
    cf_password=$(get_env_var "CCR_CF_PASSWORD") || error_and_exit "[ERROR] required env var not set: CCR_CF_PASSWORD"
    cf_cli_version=$(get_env_var "CCR_CF_CLI_VERSION" "$DEFAULT_CF_CLI_VERSION")

    local source="source:\n"
    source+="  api: $cf_api\n"
    source+="  username: $cf_username\n"
    source+="  password: $cf_password\n"
    source+="  cf_cli_version: $cf_cli_version\n"

    [ -n "$org" ] &&   source+="  org: $org\n"
    [ -n "$space" ] && source+="  space: $space\n"

    echo -e "$source"
  }

  get_source_config_with_client_credentials() {
    local cf_api client_id client_secret cf_cli_version
    cf_api=$(get_env_var "CCR_CF_API") || error_and_exit "[ERROR] required env var not set: CCR_CF_API"
    client_id=$(get_env_var "CCR_CF_CLIENT_ID") || error_and_exit "[ERROR] required env var not set: CCR_CF_CLIENT_ID"
    client_secret=$(get_env_var "CCR_CF_CLIENT_SECRET") || error_and_exit "[ERROR] required env var not set: CCR_CF_CLIENT_SECRET"
    cf_cli_version=$(get_env_var "CCR_CF_CLI_VERSION" "$DEFAULT_CF_CLI_VERSION")

    cat << EOF
source:
  api: $cf_api
  client_id: $client_id
  client_secret: $client_secret
  cf_cli_version: $cf_cli_version
EOF
  }

  get_source_config_for_cf_home() {
    local cf_cli_version=${CCR_CF_CLI_VERSION:-$DEFAULT_CF_CLI_VERSION}

    cat << EOF
source:
  cf_cli_version: $cf_cli_version
EOF
  }

  get_source_config_with_uaa_origin() {
    local cf_api cf_username cf_password cf_cli_version
    cf_api=$(get_env_var "CCR_CF_API") || error_and_exit "[ERROR] required env var not set: CCR_CF_API"
    cf_username=$(get_env_var "CCR_CF_USERNAME") || error_and_exit "[ERROR] required env var not set: CCR_CF_USERNAME"
    cf_password=$(get_env_var "CCR_CF_PASSWORD") || error_and_exit "[ERROR] required env var not set: CCR_CF_PASSWORD"
    cf_cli_version=$(get_env_var "CCR_CF_CLI_VERSION" "$DEFAULT_CF_CLI_VERSION")

    cat << EOF
source:
  api: $cf_api
  username: $cf_username
  password: $cf_password
  origin: uaa
  cf_cli_version: $cf_cli_version
EOF
  }

  login_with_cf_home() {
    [ -z "${CCR_CF_API:-}" ] && error_and_exit "environment variable not set: CCR_CF_API"
    [ -z "${CCR_CF_USERNAME:-}" ] && error_and_exit "environment variable not set: CCR_CF_USERNAME"
    [ -z "${CCR_CF_PASSWORD:-}" ] && error_and_exit "environment variable not set: CCR_CF_PASSWORD"

    cd "$(mktemp -d "$TMPDIR/.cf_home.XXXXXX")"

    CF_HOME=$PWD cf::cf api "$CCR_CF_API" >/dev/null
    CF_HOME=$PWD cf::cf auth "$CCR_CF_USERNAME" "$CCR_CF_PASSWORD" >/dev/null

    pwd
  }

  put() {
    local config=${1:?config null or not set}
    local working_dir=${2:-$(mktemp -d "$TMPDIR/put-src.XXXXXX")}

    util::yaml_to_json "$config" | "$BASE_DIR/resource/out" "$working_dir"
  }

  generate_unique_id() {
    local uuid=$(uuidgen)
    echo "${uuid,,}" # make lowercase for macOS
  }

  generate_test_name_with_spaces() {
    echo "cfclitest $(generate_unique_id)"
  }

  generate_test_name_with_hyphens() {
    echo "cfclitest-$(generate_unique_id)"
  }

  app_to_hostname() {
    echo "${1// /-}" | awk '{print tolower($0)}'
  }

  test::login() {
    local cf_api cf_username cf_password
    cf_api=$(get_env_var "CCR_CF_API") || error_and_exit "${FUNCNAME[0]} - required env var not set: CCR_CF_API"
    cf_username=$(get_env_var "CCR_CF_USERNAME") || error_and_exit "${FUNCNAME[0]} - required env var not set: CCR_CF_USERNAME"
    cf_password=$(get_env_var "CCR_CF_PASSWORD") || error_and_exit "${FUNCNAME[0]} - required env var not set: CCR_CF_PASSWORD"

    quiet cf::api "$cf_api"
    quiet cf::auth_user "$cf_username" "$cf_password"
  }

  test::logout() {
    quiet cf::cf logout
  }

  test::untarget() {
    echo "$(jq '.OrganizationFields = {"GUID":"", "Name":""} | .SpaceFields = {"GUID":"", "Name":"", "AllowSSH":false}' "$CF_HOME/.cf/config.json")" > "$CF_HOME/.cf/config.json"
  }

  test::create_org() {
    local org=${1:-}
  
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
  
    quiet cf::create_org "$org"
  }

  test::delete_org() {
    local org=${1:-}

    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"

    quiet cf::delete_org "$org"
  }

  test::create_org_and_space() {
    local org=${1:-}
    local space=${2:-}

    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    test::create_org "$org"
    quiet cf::create_space "$org" "$space"
  }

  test::delete_org_and_space() {
    local org=${1:-}
    local space=${2:-}

    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::delete_space "$org" "$space"
    test::delete_org "$org"
  }

  test::is_app_started() {
    local app_name=${1:-}
    local org=${2:-}
    local space=${3:-}

    [ -z "${app_name}" ] && error_and_exit "${FUNCNAME[0]} - app_name null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::is_app_started "$app_name"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::is_app_stopped() {
    local app_name=${1:-}
    local org=${2:-}
    local space=${3:-}

    [ -z "${app_name}" ] && error_and_exit "${FUNCNAME[0]} - app_name null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::is_app_stopped "$app_name"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::app_exists() {
    local app_name=${1:-}
    local org=${2:-}
    local space=${3:-}

    [ -z "${app_name}" ] && error_and_exit "${FUNCNAME[0]} - app_name null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::app_exists "$app_name"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::is_app_mapped_to_route() {
    local app_name=${1:-}
    local domain=${2:-}
    local org=${3:-}
    local space=${4:-}

    [ -z "${app_name}" ] && error_and_exit "${FUNCNAME[0]} - app_name null or not set"
    [ -z "${domain}" ] && error_and_exit "${FUNCNAME[0]} - domain null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::is_app_mapped_to_route "$app_name" "$domain"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::service_exists() {
    local service_instance=${1:-}
    local org=${2:-}
    local space=${3:-}

    [ -z "${service_instance}" ] && error_and_exit "${FUNCNAME[0]} - service_instance null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::service_exists "$service_instance"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::is_app_bound_to_route_service() {
    local app_name=${1:-}
    local service_instance=${2:-}
    local org=${3:-}
    local space=${4:-}
    local path=${5:-}

    [ -z "${app_name}" ] && error_and_exit "${FUNCNAME[0]} - app_name null or not set"
    [ -z "${service_instance}" ] && error_and_exit "${FUNCNAME[0]} - service_instance null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::is_app_bound_to_route_service "$app_name" "$service_instance" "$org" "$space" "$path"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::get_app_stack() {
    local app_name=${1:-}
    local org=${2:-}
    local space=${3:-}

    [ -z "${app_name}" ] && error_and_exit "${FUNCNAME[0]} - app_name null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::get_app_stack "$app_name"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::has_env() {
    local app_name=${1:-}
    local env_var_name=${2:-}
    local env_var_value=${3:-}
    local org=${4:-}
    local space=${5:-}

    [ -z "${app_name}" ] && error_and_exit "${FUNCNAME[0]} - app_name null or not set"
    [ -z "${env_var_name}" ] && error_and_exit "${FUNCNAME[0]} - env_var_name null or not set"
    [ -z "${env_var_value}" ] && error_and_exit "${FUNCNAME[0]} - env_var_value null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::has_env "$app_name" "$env_var_name" "$env_var_value"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::get_env() {
    local app_name=${1:-}
    local env_var_name=${2:-}
    local org=${3:-}
    local space=${4:-}

    [ -z "${app_name}" ] && error_and_exit "${FUNCNAME[0]} - app_name null or not set"
    [ -z "${env_var_name}" ] && error_and_exit "${FUNCNAME[0]} - env_var_name null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::get_env "$app_name" "$env_var_name"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::get_app_buildpacks() {
    local app_name=${1:-}
    local org=${2:-}
    local space=${3:-}

    [ -z "${app_name}" ] && error_and_exit "${FUNCNAME[0]} - app_name null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::get_app_buildpacks "$app_name"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::get_app_disk_quota() {
    local app_name=${1:-}
    local org=${2:-}
    local space=${3:-}

    [ -z "${app_name}" ] && error_and_exit "${FUNCNAME[0]} - app_name null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::get_app_disk_quota "$app_name"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::get_app_instances() {
    local app_name=${1:-}
    local org=${2:-}
    local space=${3:-}

    [ -z "${app_name}" ] && error_and_exit "${FUNCNAME[0]} - app_name null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::get_app_instances "$app_name"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::get_app_memory() {
    local app_name=${1:-}
    local org=${2:-}
    local space=${3:-}

    [ -z "${app_name}" ] && error_and_exit "${FUNCNAME[0]} - app_name null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::get_app_memory "$app_name"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::get_app_startup_command() {
    local app_name=${1:-}
    local org=${2:-}
    local space=${3:-}

    [ -z "${app_name}" ] && error_and_exit "${FUNCNAME[0]} - app_name null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::get_app_startup_command "$app_name"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::service_exists() {
    local service_instance=${1:-}
    local org=${2:-}
    local space=${3:-}

    [ -z "${service_instance}" ] && error_and_exit "${FUNCNAME[0]} - service_instance null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::service_exists "$service_instance"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::get_user_provided_vcap_service() {
    local app_name=${1:-}
    local service_instance=${2:-}
    local org=${3:-}
    local space=${4:-}

    [ -z "${app_name}" ] && error_and_exit "${FUNCNAME[0]} - app_name null or not set"
    [ -z "${service_instance}" ] && error_and_exit "${FUNCNAME[0]} - service_instance null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::get_user_provided_vcap_service "$app_name" "$service_instance"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::was_task_run() {
    local app_name=${1:-}
    local task_name=${2:-}

    [ -z "${app_name}" ] && error_and_exit "${FUNCNAME[0]} - app_name null or not set"
    [ -z "${task_name}" ] && error_and_exit "${FUNCNAME[0]} - task_name null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::was_task_run "$app_name" "$task_name"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::get_service_instance_plan() {
    local service_instance=${1:-}
    local org=${2:-}
    local space=${3:-}

    [ -z "${service_instance}" ] && error_and_exit "${FUNCNAME[0]} - service_instance null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::get_service_instance_plan "$service_instance"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::get_service_instance_tags() {
    local service_instance=${1:-}
    local org=${2:-}
    local space=${3:-}

    [ -z "${service_instance}" ] && error_and_exit "${FUNCNAME[0]} - service_instance null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::get_service_instance_tags "$service_instance"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::is_app_bound_to_service() {
    local app_name=${1:-}
    local service_instance=${2:-}
    local org=${3:-}
    local space=${4:-}

    [ -z "${app_name}" ] && error_and_exit "${FUNCNAME[0]} - app_name null or not set"
    [ -z "${service_instance}" ] && error_and_exit "${FUNCNAME[0]} - service_instance null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::is_app_bound_to_service "$app_name" "$service_instance"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::service_key_exists() {
    local service_instance=${1:-}
    local service_key=${2:-}
    local org=${3:-}
    local space=${4:-}

    [ -z "${service_instance}" ] && error_and_exit "${FUNCNAME[0]} - service_instance null or not set"
    [ -z "${service_key}" ] && error_and_exit "${FUNCNAME[0]} - service_key null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::service_key_exists "$service_instance" "$service_key"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::service_broker_exists() {
    local service_broker=${1:-}
    local org=${2:-}
    local space=${3:-}

    [ -z "${service_broker}" ] && error_and_exit "${FUNCNAME[0]} - service_instance null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::service_broker_exists "$service_broker"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::is_marketplace_service_available() {
    local service=${1:-}
    local plan=${2:-}
    local access_org=${3:-}
    local org=${4:-}
    local space=${5:-}

    [ -z "${service}" ] && error_and_exit "${FUNCNAME[0]} - service null or not set"
    [ -z "${plan}" ] && error_and_exit "${FUNCNAME[0]} - plan null or not set"
    [ -z "${access_org}" ] && error_and_exit "${FUNCNAME[0]} - access_org null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::is_marketplace_service_available "$service" "$plan" "$access_org"
    local status=$?
    set -e

    test::untarget

    return $status
  }

  test::network_policy_exists() {
    local source_app_name=${1:-}
    local destination_app_name=${2:-}
    local protocol=${3:-}
    local port=${4:-}
    local org=${5:-}
    local space=${6:-}

    [ -z "${source_app_name}" ] && error_and_exit "${FUNCNAME[0]} - source_app_name null or not set"
    [ -z "${destination_app_name}" ] && error_and_exit "${FUNCNAME[0]} - destination_app_name null or not set"
    [ -z "${protocol}" ] && error_and_exit "${FUNCNAME[0]} - protocol null or not set"
    [ -z "${port}" ] && error_and_exit "${FUNCNAME[0]} - port null or not set"
    [ -z "${org}" ] && error_and_exit "${FUNCNAME[0]} - org null or not set"
    [ -z "${space}" ] && error_and_exit "${FUNCNAME[0]} - space null or not set"

    quiet cf::target "$org" "$space"

    set +e
    cf::network_policy_exists "$source_app_name" "$destination_app_name" "$protocol" "$port"
    local status=$?
    set -e

    test::untarget

    return $status
  }
}
