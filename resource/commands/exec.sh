exec="$(get_option '.exec')"

logger::info "Executing $(logger::highlight "$command"): $exec"

cf::target "$org" "$space"

cf::cf $exec
h061213@sandbox():/tmp$ cat exec.sh

exec="$(get_option '.exec')"

logger::info "Executing $(logger::highlight "$command"): $exec"

cf::target "$org" "$space"

cf::cf $exec
