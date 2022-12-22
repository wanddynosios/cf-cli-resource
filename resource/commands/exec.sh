exec="$(get_option '.exec')"
exec_timeout="$(get_option '.exec_timeout')"

logger::info "Executing $(logger::highlight "$command"): $exec"

cf::target "$org" "$space"


if [ ! -z "${exec_timeout}" ] ; then
  logger::info "using timeout $(logger::highlight "${exec_timeout}")"
  # we cannot use cf::cf because timeout does not work with functions
  if timeout ${exec_timeout} "$CF_CLI" $exec ; then
    return
  else
    RC=$?
    if [ $RC -eq 124 ]; then
      echo "Timeout occurred"
     fi
   fi
else
  cf::cf $exec
fi

 