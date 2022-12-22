exec="$(get_option '.exec')"

logger::info "Executing $(logger::highlight "$command"): $exec"

cf::target "$org" "$space"

cf::cf $exec
