export OCAMLRUNPARAM=b
ana=${1-"file"}
file=${2-"tests/file.c"}
result=${3-"html"}
debug=${debug-"false"}
spec=${spec-"18-file/file.optimistic"}
if [ $ana == "file" ]; then
    ana="$ana --set ana.file.optimistic true"
elif [ $ana == "spec" ]; then
    ana="$ana --sets ana.spec.file tests/regression/${spec}.spec"
fi
cmd="./goblint --sets ana.activated[0][+] $ana --sets result $result --enable colors --set dbg.showtemps true --set dbg.debug $debug $file"
echo -e "$(tput setaf 6)$cmd$(tput sgr 0)"
$cmd
