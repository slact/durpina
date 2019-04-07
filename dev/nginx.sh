#!/bin/zsh
DEVDIR=`pwd`

#SRCDIR=$(readlink -m $DEVDIR/../src) #not available on platforms like freebsd
SRCDIR=`perl -e "use Cwd realpath; print realpath(\"$DEVDIR/../src\");"`

VALGRIND_OPT=( "--tool=memcheck" "--track-origins=yes" "--read-var-info=yes" )

VG_MEMCHECK_OPT=( "--leak-check=full" "--show-leak-kinds=all" "--leak-check-heuristics=all" "--keep-stacktraces=alloc-and-free" "--suppressions=${DEVDIR}/vg.supp" )

#expensive definedness checks (newish option)
VG_MEMCHECK_OPT+=( "--expensive-definedness-checks=yes")

#long stack traces
VG_MEMCHECK_OPT+=("--num-callers=20")

#generate suppresions
#VG_MEMCHECK_OPT+=("--gen-suppressions=all")

#track files
#VG_MEMCHECK_OPT+=("--track-fds=yes")
NGINX=/opt/openresty/bin/openresty


WORKERS=5
NGINX_DAEMON="off"
NGINX_CONF=""
ACCESS_LOG="/dev/null"
ERROR_LOG="stderr"
ERRLOG_LEVEL="notice"
TMPDIR=""
MEM="32M"

DEBUGGER_NAME="kdbg"
DEBUGGER_CMD="dbus-run-session kdbg -p %s $NGINX"

#DEBUGGER_NAME="nemiver"
#DEBUGGER_CMD="nemiver --attach=%s $NGINX"

REDIS_CONF="$DEVDIR/redis.conf"
REDIS_PORT=8537


_cacheconf="  proxy_cache_path _CACHEDIR_ levels=1:2 keys_zone=cache:1m; \\n  server {\\n       listen 8007;\\n       location / { \\n          proxy_cache cache; \\n      }\\n  }\\n"

NGINX_CONF_FILE="nginx.conf"

for opt in $*; do
  if [[ "$opt" = <-> ]]; then
    WORKERS=$opt
  fi
  case $opt in
    leak|leakcheck|valgrind|memcheck)
      valgrind=1
      VALGRIND_OPT+=($VG_MEMCHECK_OPT);;
    debug-memcheck)
      valgrind=1
      VALGRIND_OPT+=($VG_MEMCHECK_OPT)
      VALGRIND_OPT+=( "--vgdb=yes" "--vgdb-error=1" )
      #ATTACH_DDD=1
      ;;
    cachegrind)
      VALGRIND_OPT=( "--tool=cachegrind" )
      valgrind=1;;
    cache)
      CACHE=1;;
    access)
      ACCESS_LOG="/dev/stdout";;
    debugmaster|debug-master)
      WORKERS=1
      debug_master=1
      NGINX_DAEMON="off"
      ;;
    debug)
      WORKERS=1
      NGINX_DAEMON="on"
      debugger=1
      ;;
    debug=*)
      debug_what="${opt:6}"
      if [[ $debug_what == "master" ]]; then
        WORKERS=1
        debug_master=1
        NGINX_DAEMON="off"
      else
        NGINX_DAEMON="on"
        debugger=1
        child_text_match=$debug_what
      fi
      ;;
    debuglog)
      ERRLOG_LEVEL="debug"
      ;;
    loglevel=*)
      ERRLOG_LEVEL="${opt:9}"
      ;;
    errorlog=*)
      ERROR_LOG="${opt:9}"
      ;;
    silent)
      ERROR_LOG="/dev/null"
      SILENT=1
      ;;
    sudo)
      SUDO="sudo";;
  esac
done

NGINX_CONFIG=`pwd`/$NGINX_CONF_FILE
NGINX_TEMP_CONFIG=`pwd`/.nginx.thisrun.conf
NGINX_PIDFILE=`pwd`/.pid
NGINX_OPT=( -p `pwd`/ 
    -c $NGINX_TEMP_CONFIG
)
cp -f $NGINX_CONFIG $NGINX_TEMP_CONFIG

_sed_i_conf() {
  sed $1 $NGINX_TEMP_CONFIG > $NGINX_TEMP_CONFIG.tmp && mv $NGINX_TEMP_CONFIG.tmp $NGINX_TEMP_CONFIG
}

conf_replace(){
    if [[ -z $SILENT ]]; then
      echo "$1 $2"
    fi
    _sed_i_conf "s|^\( *\)\($1\)\( *\).*|\1\2\3$2;|g"
}

_semver_gteq() {
  ruby -rrubygems -e "exit Gem::Version.new(('$1').match(/\/?([.\d]+)/)[1]) < Gem::Version.new(('$2').match(/^[^\s+]/)) ? 0 : 1"
  return $?
}

ulimit -c unlimited

if [[ ! -z $NGINX_CONF ]]; then
    NGINX_OPT+=( -g "$NGINX_CONF" )
fi
#echo $NGINX_CONF
#echo $NGINX_OPT

export ASAN_SYMBOLIZER_PATH=/usr/bin/llvm-symbolizer
export ASAN_OPTIONS=symbolize=1
if [[ -z $SILENT ]]; then
  echo "nginx $NGINX_OPT"
fi
conf_replace "access_log" $ACCESS_LOG
conf_replace "error_log" "$ERROR_LOG $ERRLOG_LEVEL"
conf_replace "worker_processes" $WORKERS
conf_replace "daemon" $NGINX_DAEMON
conf_replace "pid" $NGINX_PIDFILE
conf_replace "working_directory" "\"$(pwd)\""

_path=$(readlink -f ../lib)
ppath="$_path/?.lua;$_path/?/init.lua"
lua_ppath=";/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;/usr/lib/lua/5.1/?.lua;/usr/lib/lua/5.1/?/init.lua"
conf_replace "lua_package_path" "\"$ppath;$lua_ppath;;;\""
if [[ ! -z $CACHE ]]; then
  _sed_i_conf "s|^ *#cachetag.*|${_cacheconf}|g"
  tmpdir=`pwd`"/.tmp"
  mkdir $tmpdir 2>/dev/null
  _sed_i_conf "s|_CACHEDIR_|\"$tmpdir\"|g"
fi

debugger_pids=()
TRAPINT() {
  if [[ $debugger == 1 ]]; then
    sudo kill $debugger_pids
  fi
  kill `cat $NGINX_PIDFILE`
}
TRAPTERM() {
  if [[ $debugger == 1 ]]; then
    sudo kill $debugger_pids
  fi
  kill `cat $NGINX_PIDFILE`
}

attach_debugger() {
  master_pid=`cat $NGINX_PIDFILE`
  while [[ -z $child_pids ]]; do
    if [[ -z $child_text_match ]]; then
      child_pids=`pgrep -P $master_pid`
    else
      child_pids=`pgrep -P $master_pid -f $child_text_match`
    fi
    sleep 0.1
  done
  while read -r line; do
    echo "attaching $1 to $line"
    sudo $(printf $2 $line) &
    debugger_pids+="$!"
  done <<< $child_pids
  echo "$1 at $debugger_pids"
}

if [[ ! -f $NGINX ]]; then
  echo "$NGINX not found"
  exit 1
fi

if [[ $debugger == 1 ]]; then
  $SUDO $NGINX $NGINX_OPT
  if ! [ $? -eq 0 ]; then; 
    echo "failed to start nginx"; 
    exit 1
  fi
  sleep 0.2
  attach_debugger "$DEBUGGER_NAME" "$DEBUGGER_CMD"
  wait $debugger_pids
  kill $master_pid
elif [[ $debug_master == 1 ]]; then
  pushd $SRCDIR
  sudo kdbg -a "$NGINX_OPT" "$NGINX"
  popd
elif [[ $valgrind == 1 ]]; then
  mkdir ./coredump 2>/dev/null
  pushd ./coredump >/dev/null
  if [[ $ATTACH_DDD == 1 ]]; then
    $SUDO valgrind $VALGRIND_OPT .$NGINX $NGINX_OPT &
    _master_pid=$!
    echo "nginx at $_master_pid"
    sleep 4
    attach_ddd_vgdb $_master_pid
    wait $debugger_pids
    kill $master_pid
  else
    echo $SUDO valgrind $VALGRIND_OPT .$NGINX $NGINX_OPT
    $SUDO valgrind $VALGRIND_OPT .$NGINX $NGINX_OPT
  fi
  popd >/dev/null
elif [[ $alleyoop == 1 ]]; then
  alleyoop $NGINX $NGINX_OPT
else
  $SUDO $NGINX $NGINX_OPT &
  wait $!
fi
