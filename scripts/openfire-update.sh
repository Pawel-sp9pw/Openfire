#!/usr/bin/env bash
# Experimental 5.1.2 hotfix for the Pawel-sp9pw/Openfire fork.
# Does not change package version, database schema, config files or plugins.
set -Eeuo pipefail
umask 077

REPO=https://github.com/Pawel-sp9pw/Openfire.git
COMMIT=1d351a49d2d92be81940ac5b38a2cd1bcdedc9d7
SERVICE=openfire
BACKUP_ROOT=/var/backups/openfire-sp9pw
BUILDER=openfire-build
CLASS1=org/jivesoftware/openfire/csi/CsiManager.class
CLASS2=org/jivesoftware/openfire/handler/IQMessageCarbonsHandler.class

die() { printf 'BLAD: %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s ==\n' "$*"; }
usage() {
    cat <<'HELP'
Uzycie:
  bash openfire-update.sh check
  bash openfire-update.sh install NAZWA_BAZY
  bash openfire-update.sh rollback /var/backups/openfire-sp9pw/KATALOG

Lokalny PostgreSQL: pg_dump przez konto postgres.
Zdalny PostgreSQL: ustaw PGHOST, PGPORT, PGUSER i PGPASSFILE
(plik hasel 0600, tylko do odczytu przez roota).
OPENFIRE_PORT=5222 (domyslnie); podaj inny port jesli uzywasz niestandardowego.

Wymagania: git, default-jdk-headless, unzip, postgresql-client, curl,
ca-certificates, iproute2 i standardowe narzedzia Debiana.
Przed install wykonaj snapshot LXC oraz sprawdz nazwe bazy.
HELP
}
if [[ ${1:-} == --help || ${1:-} == -h || $# == 0 ]]; then usage; exit 0; fi
[[ $EUID -eq 0 ]] || die 'Uruchom jako root wewnatrz LXC.'
for c in git java javac jar javap unzip pg_dump pg_restore psql     flock runuser useradd sha256sum systemctl dpkg-query apt-mark ss realpath tar; do
    command -v "$c" >/dev/null || die "Brak narzedzia: $c"
done
exec 9>/run/lock/openfire-sp9pw.lock
flock -n 9 || die 'Inna aktualizacja jest w toku.'
[[ $(dpkg-query -W -f='${db:Status-Abbrev}' openfire 2>/dev/null) == ii* ||
   $(dpkg-query -W -f='${db:Status-Abbrev}' openfire 2>/dev/null) == hi* ]] ||
    die 'Nie znaleziono zainstalowanego pakietu openfire.'
VERSION=$(dpkg-query -W -f='${Version}' openfire)
[[ $VERSION =~ ^([0-9]+:)?5\.1\.2([+-].*)?$ ]] ||
    die "Ten hotfix jest tylko dla Openfire 5.1.2 (masz $VERSION)."
[[ -d /etc/openfire && -d /var/lib/openfire ]] ||
    die 'Nie rozpoznano standardowego ukladu instalacji Debian.'
PORT=${OPENFIRE_PORT:-5222}
[[ $PORT =~ ^[0-9]{1,5}$ ]] && (( 10#$PORT > 0 && 10#$PORT <= 65535 )) ||
    die 'Nieprawidlowy OPENFIRE_PORT.'
PORT=$((10#$PORT))

find_core() {
    local f entries
    local -a candidates=()
    while IFS= read -r f; do
        [[ $f == /usr/share/openfire/lib/*.jar && -f $f && ! -L $f ]] || continue
        entries=$(unzip -Z1 "$f" 2>/dev/null) || continue
        if grep -Fx "$CLASS1" <<<"$entries" >/dev/null &&
           grep -Fx "$CLASS2" <<<"$entries" >/dev/null; then
            candidates+=("$f")
        fi
    done < <(dpkg-query -L openfire)
    [[ ${#candidates[@]} == 1 ]] || die 'Nie znaleziono dokladnie jednego pakietowego JAR rdzenia.'
    printf '%s\n' "${candidates[0]}"
}
TARGET=$(find_core)
has_port() { [[ -n $(ss -H -ltn "sport = :$PORT") ]]; }
is_held() { apt-mark showhold | grep -Fx openfire >/dev/null; }
healthy() {
    systemctl is-active --quiet "$SERVICE" &&
        { [[ $CHECK_PORT == 0 ]] || has_port; }
}
wait_health() {
    local i
    for ((i=0;i<40;i++)); do
        if healthy; then
            sleep 3
            if healthy; then return 0; fi
        fi
        sleep 1
    done
    return 1
}
atomic_copy() {
    local from=$1 temp
    temp=$(mktemp --tmpdir="$(dirname "$TARGET")" .sp9pw-XXXXXX)
    if ! cp --preserve=all -- "$from" "$temp" || ! mv -Tf -- "$temp" "$TARGET"; then
        rm -f -- "$temp"
        return 1
    fi
}
check() {
    say 'Weryfikacja instalacji'
    printf 'Pakiet: %s\nJAR: %s\nCommit hotfix: %s\n' "$VERSION" "$TARGET" "$COMMIT"
    java -version
    if is_held; then echo 'APT hold: tak'; else echo 'APT hold: nie'; fi
    systemctl is-active "$SERVICE" || true
    if has_port; then echo "Port $PORT nasluchuje."; else echo "Port $PORT nie nasluchuje."; fi
}
if [[ $1 == check && $# == 1 ]]; then check; exit 0; fi

CHECK_PORT=0
if has_port; then CHECK_PORT=1; fi
[[ $CHECK_PORT == 1 ]] || echo "UWAGA: port $PORT nie nasluchuje; test startu ograniczony do systemd." >&2

if [[ $1 == rollback && $# == 2 ]]; then
    backup=$(realpath -e -- "$2")
    [[ $backup == "$BACKUP_ROOT/"* && -d $backup && ! -L $backup ]] || die 'Nieprawidlowy katalog kopii.'
    [[ $(cat "$backup/target") == "$TARGET" && $(cat "$backup/version") == "$VERSION" ]] ||
        die 'Kopia nie odpowiada biezacej instalacji.'
    (cd "$backup" && sha256sum -c SHA256SUMS)
    cmp -s "$TARGET" "$backup/patched.jar" ||
        die 'Biezacy JAR nie odpowiada tej poprawce; nie nadpisuje nowszej lub innej instalacji.'
    say 'Przywracanie oryginalnego rdzenia'
    systemctl stop "$SERVICE"
    if atomic_copy "$backup/original.jar" &&
       systemctl start "$SERVICE" && wait_health; then
        if [[ $(cat "$backup/held-before") == 0 ]]; then apt-mark unhold openfire; fi
        echo 'Przywrocono oryginalny JAR. Baza PostgreSQL i konfiguracja nie byly odtwarzane.'
    else
        echo 'Rollback nie przeszedl testu startu; proba powrotu do hotfixa.' >&2
        systemctl stop "$SERVICE" || true
        atomic_copy "$backup/patched.jar" || true
        systemctl start "$SERVICE" || true
        die "Sprawdz journalctl -u openfire; kopia: $backup"
    fi
    exit 0
fi
[[ $1 == install && $# == 2 && -n $2 ]] || { usage; exit 2; }
DB=$2
systemctl is-active --quiet "$SERVICE" || die 'Openfire musi dzialac przed aktualizacja.'
if [[ -n ${PGHOST:-} ]]; then
    pg() { "$@"; }
else
    id postgres >/dev/null 2>&1 || die 'Brak lokalnego konta postgres; dla zdalnej bazy ustaw PGHOST.'
    pg() { runuser -u postgres -- "$@"; }
fi
pg psql -X -w --dbname="$DB" -Atqc     "SELECT to_regclass('ofproperty') IS NOT NULL AND to_regclass('ofuser') IS NOT NULL" |
    grep -Fx t >/dev/null || die 'Nie mozna potwierdzic bazy Openfire (sprawdz nazwe i polaczenie PostgreSQL).'

work=''
backup=''
stopped=0
replaced=0
hold_changed=0
success=0
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    if [[ $success == 0 ]]; then
        if [[ $replaced == 1 ]]; then
            echo 'Niepowodzenie; przywracam poprzedni JAR.' >&2
            systemctl stop "$SERVICE"
            if ! atomic_copy "$backup/original.jar"; then
                echo "KRYTYCZNE: nie przywrocono JAR. Kopia: $backup" >&2
                rc=1
            fi
        fi
        if [[ $stopped == 1 ]]; then
            systemctl start "$SERVICE" && wait_health ||
                echo "KRYTYCZNE: sprawdz journalctl -u $SERVICE oraz kopie $backup" >&2
        fi
        if [[ $hold_changed == 1 ]]; then apt-mark unhold openfire; fi
    fi
    [[ -z $work ]] || rm -rf -- "$work"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
say 'Budowanie poprawki i uruchamianie testow (serwer nadal dziala)'
if ! id "$BUILDER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$BUILDER"
fi
[[ $(id -u "$BUILDER") != 0 ]] || die 'Konto budujace nie moze byc rootem.'
work=$(mktemp -d /var/tmp/openfire-build.XXXXXXXX)
chown "$BUILDER" "$work"
runuser -u "$BUILDER" -- env -i HOME="$work" PATH=/usr/local/bin:/usr/bin:/bin     LANG=C.UTF-8 GIT_TERMINAL_PROMPT=0 MAVEN_USER_HOME="$work/.m2" JAVA_TOOL_OPTIONS="-Duser.home=$work" bash -s -- "$work" "$REPO" "$COMMIT" <<'BUILD'
set -Eeuo pipefail
cd "$1"
git init -q src
cd src
git remote add origin "$2"
git fetch --depth 1 origin "$3"
git checkout -q --detach FETCH_HEAD
[[ $(git rev-parse HEAD) == "$3" ]]
bash ./mvnw -B -ntp -Dmaven.repo.local="$1/.m2/repository" -pl xmppserver -am     -Dtest=CsiManagerTest -Dsurefire.failIfNoSpecifiedTests=false verify
BUILD
report="$work/src/xmppserver/target/surefire-reports/TEST-org.jivesoftware.openfire.csi.CsiManagerTest.xml"
[[ -s $report ]] || die 'Maven nie wygenerowal raportu testow CSI.'
grep -E 'tests="[1-9][0-9]*"' "$report" >/dev/null || die 'Nie wykonano testow CSI.'
grep -F 'failures="0"' "$report" >/dev/null && grep -F 'errors="0"' "$report" >/dev/null ||
    die 'Testy CSI nie przeszly.'
classes="$work/src/xmppserver/target/classes"
[[ -s "$classes/$CLASS1" && -s "$classes/$CLASS2" ]] || die 'Brak skompilowanych klas.'
# Compare non-private binary signatures before replacing the two classes.
for class in "$CLASS1" "$CLASS2"; do
    name=${class%.class}; name=${name//\//.}
    javap -package -s -classpath "$TARGET" "$name" >"$work/old.api"
    javap -package -s -classpath "$classes" "$name" >"$work/new.api"
    diff -u "$work/old.api" "$work/new.api" || die "Niezgodne API klasy $name."
done
if unzip -Z1 "$TARGET" | grep -Ei '^META-INF/[^/]+\.(SF|RSA|DSA|EC)$' >/dev/null; then
    die 'JAR jest podpisany; nie modyfikuje podpisanego archiwum.'
fi

say 'Kopia konfiguracji, rdzenia i danych PostgreSQL'
[[ ! -L $BACKUP_ROOT ]] || die 'Katalog backupu nie moze byc dowiazaniem.'
install -d -m 0700 "$BACKUP_ROOT"
backup=$(mktemp -d "$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S).XXXXXXXX")
printf '%s\n' "$backup"
printf '%s\n' "$TARGET" >"$backup/target"
printf '%s\n' "$VERSION" >"$backup/version"
printf '%s\n' "$COMMIT" >"$backup/commit"
if is_held; then echo 1 >"$backup/held-before"; else echo 0 >"$backup/held-before"; fi

stopped=1
systemctl stop "$SERVICE"
if systemctl is-active --quiet "$SERVICE"; then die 'Nie udalo sie zatrzymac Openfire.'; fi
cp -a -- "$TARGET" "$backup/original.jar"
cp -a -- "$TARGET" "$backup/patched.jar"
paths=(etc/openfire var/lib/openfire usr/share/openfire)
for p in etc/default/openfire etc/init.d/openfire etc/systemd/system/openfire.service     etc/systemd/system/openfire.service.d; do
    [[ ! -e /$p && ! -L /$p ]] || paths+=("$p")
done
tar --acls --xattrs -C / -cpf "$backup/files.tar" -- "${paths[@]}"
tar -tf "$backup/files.tar" >/dev/null
pg pg_dump -w --format=custom --dbname="$DB" >"$backup/postgres.dump"
pg_restore -l "$backup/postgres.dump" >/dev/null

# Update ONLY two class entries in the existing package JAR, retaining all other resources.
jar --update --file "$backup/patched.jar" -C "$classes" "$CLASS1" -C "$classes" "$CLASS2"
chown --reference="$backup/original.jar" "$backup/patched.jar"
chmod --reference="$backup/original.jar" "$backup/patched.jar"
for class in "$CLASS1" "$CLASS2"; do
    unzip -p "$backup/patched.jar" "$class" | cmp - "$classes/$class" ||
        die "Weryfikacja klasy $class nie powiodla sie."
done
(cd "$backup" && sha256sum original.jar patched.jar files.tar postgres.dump >SHA256SUMS &&
    sha256sum -c SHA256SUMS)
if [[ $(cat "$backup/held-before") == 0 ]]; then
    hold_changed=1
    apt-mark hold openfire
fi

say 'Instalacja hotfixa'
replaced=1
atomic_copy "$backup/patched.jar"
systemctl start "$SERVICE"
wait_health || die 'Openfire nie przeszedl testu startu.'
success=1
say 'Hotfix zainstalowany'
printf 'Commit: %s\nKopia: %s\n' "$COMMIT" "$backup"
printf 'Rollback: bash %q rollback %q\n' "$0" "$backup"
echo 'Sprawdz logowanie i wylogowanie dwoch klientow Spark. APT hold pozostaje aktywny.'
