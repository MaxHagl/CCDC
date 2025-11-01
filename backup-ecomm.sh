#!/usr/bin/env bash
# backup-ecomm.sh — PrestaShop catalog backup (products/variants/categories/mappings + images)
# Works with Docker *or* local installs. Outputs TSVs (+ optional images.tar.gz).
# Minimal deps: bash, tar; plus mysql client in local mode.

set -euo pipefail

# -------- Defaults (override with flags) --------
MODE="auto"                                       # auto | docker | local
APP_CTN="${APP_CTN:-prestashop-prestashop-1}"     # docker app container
DB_CTN="${DB_CTN:-prestashop-db-1}"               # docker db container
PS_ROOT="${PS_ROOT:-/var/www/html}"               # local PS root
OUT_DIR="${OUT_DIR:-/opt/backups/prestashop-catalog}"
INCLUDE_IMAGES=1                                   # 1 = include product images tarball
LANG_ID=""                                         # auto-detect if empty
TABLE_PREFIX=""                                    # auto-detect if empty

# Local DB overrides (optional)
DB_HOST="" DB_PORT="" DB_NAME="" DB_USER="" DB_PASS=""

usage() {
  cat <<EOF
Usage: sudo $0 [options]

  --docker                 Force Docker mode
  --local                  Force local mode
  --app NAME               App container (default: $APP_CTN)
  --db NAME                DB container  (default: $DB_CTN)
  --root DIR               PrestaShop root (local mode, default: $PS_ROOT)
  --to DIR                 Output directory (default: $OUT_DIR)
  --no-images              Skip archiving product images
  --lang ID                Language id (default: auto from PS_LANG_DEFAULT)
  --prefix ps_             Table prefix (default: auto-detect; falls back to ps_)
  --db-host HOST           Local mode DB host
  --db-port PORT           Local mode DB port (default: 3306)
  --db-name NAME           Local mode DB name
  --db-user USER           Local mode DB user
  --db-pass PASS           Local mode DB password
  -h|--help                Show help
EOF
}

# -------- Parse flags --------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --docker) MODE="docker"; shift;;
    --local)  MODE="local"; shift;;
    --app)    APP_CTN="$2"; shift 2;;
    --db)     DB_CTN="$2"; shift 2;;
    --root)   PS_ROOT="$2"; shift 2;;
    --to)     OUT_DIR="$2"; shift 2;;
    --no-images) INCLUDE_IMAGES=0; shift;;
    --lang)   LANG_ID="$2"; shift 2;;
    --prefix) TABLE_PREFIX="$2"; shift 2;;
    --db-host) DB_HOST="$2"; shift 2;;
    --db-port) DB_PORT="$2"; shift 2;;
    --db-name) DB_NAME="$2"; shift 2;;
    --db-user) DB_USER="$2"; shift 2;;
    --db-pass) DB_PASS="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "[ERR] Unknown option: $1"; usage; exit 1;;
  esac
done

have(){ command -v "$1" >/dev/null 2>&1; }

# -------- Decide mode --------
if [[ "$MODE" == "auto" ]]; then
  if have docker && docker ps --format '{{.Names}}' | grep -Eq "^(${APP_CTN}|${DB_CTN})$"; then
    MODE="docker"
  else
    MODE="local"
  fi
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="${OUT_DIR%/}/export-${TS}"
mkdir -p "$DEST"

# -------- SQL plumbing (filled per-mode) --------
sql_exec() { :; }     # reads SQL from stdin, writes rows to stdout (no header)
run_sql() { :; }      # run a one-liner query and echo result (no header)

# -------- Docker mode --------
if [[ "$MODE" == "docker" ]]; then
  command -v docker >/dev/null || { echo "[ERR] docker not found"; exit 1; }
  APP_ID="$(docker ps -q -f "name=^/${APP_CTN}$")"
  DB_ID="$(docker ps -q -f "name=^/${DB_CTN}$")"
  [[ -n "$APP_ID" ]] || { echo "[ERR] App container '$APP_CTN' not running"; exit 1; }
  [[ -n "$DB_ID"  ]] || { echo "[ERR] DB container '$DB_CTN' not running"; exit 1; }

  # creds from app env, fallback to DB env
  read -r DB_NAME DB_USER DB_PASS < <(docker exec "$APP_ID" sh -lc \
    'printf "%s %s %s\n" "${DB_NAME:-prestashop}" "${DB_USER:-pshop}" "${DB_PASSWD:-changeme_db}"')
  if [[ -z "$DB_NAME$DB_USER$DB_PASS" || "$DB_NAME" = " " ]]; then
    read -r DB_NAME DB_USER DB_PASS < <(docker exec "$DB_ID" sh -lc \
      'printf "%s %s %s\n" "${MYSQL_DATABASE:-prestashop}" "${MYSQL_USER:-pshop}" "${MYSQL_PASSWORD:-changeme_db}"')
  fi

  DBCLI="$(docker exec "$DB_ID" sh -lc 'command -v mariadb >/dev/null && echo mariadb || echo mysql')"

  sql_exec() { docker exec -i "$DB_ID" sh -lc "$DBCLI -N -B -u'${DB_USER}' -p'${DB_PASS}' '${DB_NAME}'"; }
  run_sql()  { printf "%s" "$1" | sql_exec; }

  # prefix/lang auto
  [[ -n "$TABLE_PREFIX" ]] || TABLE_PREFIX="$(run_sql "SELECT COALESCE(SUBSTRING_INDEX(table_name,'product',1),'ps_') FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name LIKE '%product' LIMIT 1;")"
  [[ -n "$TABLE_PREFIX" ]] || TABLE_PREFIX="ps_"
  [[ -n "$LANG_ID" ]] || LANG_ID="$(run_sql "SELECT value FROM ${TABLE_PREFIX}configuration WHERE name='PS_LANG_DEFAULT' LIMIT 1;")"
  [[ -n "$LANG_ID" ]] || { echo "[ERR] Could not detect PS_LANG_DEFAULT"; exit 1; }

  echo "[MODE] docker"
  echo "[INFO] Output: $DEST"
  echo "[INFO] DB: ${DB_NAME} user=${DB_USER} prefix=${TABLE_PREFIX} lang=${LANG_ID}"

  printf 'SET SESSION group_concat_max_len=8192;\n' | sql_exec >/dev/null

  write_tsv() { # $1=outfile  $2=header ; SQL is provided via STDIN
    local outfile="$1" header="$2"
    printf "%s\n" "$header" > "$outfile"
    sql_exec >> "$outfile"
  }

  # PRODUCTS
  write_tsv "${DEST}/products.tsv" \
"id_product\treference\tname\tprice_tax_excl\tquantity\tactive\tdefault_category\tean13\tupc\tisbn\tvisibility\tdate_add\tdate_upd" <<SQL

SELECT p.id_product, p.reference,
       REPLACE(REPLACE(pl.name, '\t',' '), '\n',' ') AS name,
       p.price, COALESCE(sa.quantity,0), p.active,
       REPLACE(REPLACE(cl.name, '\t',' '), '\n',' ') AS default_category,
       p.ean13, p.upc, p.isbn, p.visibility, p.date_add, p.date_upd
FROM ${TABLE_PREFIX}product p
LEFT JOIN ${TABLE_PREFIX}product_lang pl
       ON pl.id_product=p.id_product AND pl.id_lang=${LANG_ID}
LEFT JOIN ${TABLE_PREFIX}stock_available sa
       ON sa.id_product=p.id_product AND sa.id_product_attribute=0
LEFT JOIN ${TABLE_PREFIX}category_lang cl
       ON cl.id_category=p.id_category_default AND cl.id_lang=${LANG_ID}
ORDER BY p.id_product;
SQL

  # VARIANTS
  write_tsv "${DEST}/variants.tsv" \
"id_product_attribute\tid_product\tcombination\treference\tprice_impact\tweight\tquantity\tean13\tupc" <<SQL

SELECT pa.id_product_attribute, pa.id_product,
       REPLACE(REPLACE(
         GROUP_CONCAT(CONCAT(agl.name, ': ', al.name) ORDER BY agl.name SEPARATOR ', ')
       , '\t',' '), '\n',' ') AS combination,
       pa.reference, COALESCE(pas.price,0), pa.weight, COALESCE(sa.quantity,0), pa.ean13, pa.upc
FROM ${TABLE_PREFIX}product_attribute pa
LEFT JOIN ${TABLE_PREFIX}product_attribute_shop pas
       ON pas.id_product_attribute=pa.id_product_attribute
LEFT JOIN ${TABLE_PREFIX}product_attribute_combination pac
       ON pac.id_product_attribute=pa.id_product_attribute
LEFT JOIN ${TABLE_PREFIX}attribute a ON a.id_attribute=pac.id_attribute
LEFT JOIN ${TABLE_PREFIX}attribute_lang al
       ON al.id_attribute=a.id_attribute AND al.id_lang=${LANG_ID}
LEFT JOIN ${TABLE_PREFIX}attribute_group_lang agl
       ON agl.id_attribute_group=a.id_attribute_group AND agl.id_lang=${LANG_ID}
LEFT JOIN ${TABLE_PREFIX}stock_available sa
       ON sa.id_product_attribute=pa.id_product_attribute
GROUP BY pa.id_product_attribute, pa.id_product, pa.reference, pas.price, pa.weight, sa.quantity, pa.ean13, pa.upc
ORDER BY pa.id_product, pa.id_product_attribute;
SQL

  # CATEGORIES
  write_tsv "${DEST}/categories.tsv" \
"id_category\tname\tid_parent\tactive\tposition" <<SQL

SELECT c.id_category,
       REPLACE(REPLACE(cl.name, '\t',' '), '\n',' ') AS name,
       c.id_parent, c.active, c.position
FROM ${TABLE_PREFIX}category c
JOIN ${TABLE_PREFIX}category_lang cl
     ON cl.id_category=c.id_category AND cl.id_lang=${LANG_ID}
ORDER BY c.id_parent, c.position, c.id_category;
SQL

  # PRODUCT↔CATEGORY
  write_tsv "${DEST}/product_categories.tsv" \
"id_product\tid_category" <<SQL
SELECT id_product, id_category
FROM ${TABLE_PREFIX}category_product
ORDER BY id_product, id_category;
SQL

  # IMAGES MAP
  write_tsv "${DEST}/images.tsv" \
"id_image\tid_product\tcover\tposition" <<SQL
SELECT id_image, id_product, cover, position
FROM ${TABLE_PREFIX}image
ORDER BY id_product, position, id_image;
SQL

  # IMAGES TAR
  if [[ "$INCLUDE_IMAGES" -eq 1 ]]; then
    echo "[STEP] Archiving images (from ${APP_CTN}:/var/www/html/img/p)…"
    docker exec "$APP_ID" sh -lc "tar -C /var/www/html/img -czf - p" > "${DEST}/images.tar.gz"
  fi

# -------- Local mode --------
else
  # need mysql/mariadb client
  if have mariadb; then MYSQL_BIN="mariadb"; elif have mysql; then MYSQL_BIN="mysql"; else
    echo "[ERR] Need mysql or mariadb client. Try: sudo apt-get install -y mariadb-client"
    exit 1
  fi

  P6="$PS_ROOT/config/settings.inc.php"
  P8="$PS_ROOT/app/config/parameters.php"

  if [[ -z "$DB_NAME$DB_USER$DB_PASS$DB_HOST" ]]; then
    if [[ -f "$P8" ]] && have php; then
      IFS=" " read -r DB_HOST DB_PORT DB_NAME DB_USER DB_PASS TABLE_PREFIX < <(
        php -r '
          $p = include "'$P8'";
          $a = $p["parameters"];
          echo $a["database_host"]," ",
               ($a["database_port"]??"3306")," ",
               $a["database_name"]," ",
               $a["database_user"]," ",
               $a["database_password"]," ",
               ($a["database_prefix"]??"ps_");'
      )
    elif [[ -f "$P8" ]]; then
      DB_HOST="$(grep -Po "database_host'\s*=>\s*'[^']*" "$P8" | sed "s/.*'//")"
      DB_PORT="$(grep -Po "database_port'\s*=>\s*'[^']*" "$P8" | sed "s/.*'//" || echo 3306)"
      DB_NAME="$(grep -Po "database_name'\s*=>\s*'[^']*" "$P8" | sed "s/.*'//")"
      DB_USER="$(grep -Po "database_user'\s*=>\s*'[^']*" "$P8" | sed "s/.*'//")"
      DB_PASS="$(grep -Po "database_password'\s*=>\s*'[^']*" "$P8" | sed "s/.*'//")"
      TABLE_PREFIX="$(grep -Po "database_prefix'\s*=>\s*'[^']*" "$P8" | sed "s/.*'//" || echo ps_)"
    elif [[ -f "$P6" ]]; then
      DB_HOST="$(grep -Po "define\('_DB_SERVER_',\s*'[^']*" "$P6" | sed "s/.*'//")"
      DB_PORT="3306"
      DB_NAME="$(grep -Po "define\('_DB_NAME_',\s*'[^']*" "$P6" | sed "s/.*'//")"
      DB_USER="$(grep -Po "define\('_DB_USER_',\s*'[^']*" "$P6" | sed "s/.*'//")"
      DB_PASS="$(grep -Po "define\('_DB_PASSWD_',\s*'[^']*" "$P6" | sed "s/.*'//")"
      TABLE_PREFIX="$(grep -Po "define\('_DB_PREFIX_',\s*'[^']*" "$P6" | sed "s/.*'//")"
    else
      echo "[ERR] Could not find PrestaShop config; pass --db-* flags."
      exit 1
    fi
  fi
  DB_PORT="${DB_PORT:-3306}"
  TABLE_PREFIX="${TABLE_PREFIX:-ps_}"

  CNF="$(mktemp)"; chmod 600 "$CNF"
  cat >"$CNF" <<EOF
[client]
host=$DB_HOST
port=$DB_PORT
user=$DB_USER
password=$DB_PASS
default-character-set=utf8mb4
EOF

  sql_exec() { "$MYSQL_BIN" --defaults-extra-file="$CNF" -N -B "$DB_NAME"; }
  run_sql()  { printf "%s" "$1" | sql_exec; }

  [[ -n "$LANG_ID" ]] || LANG_ID="$(run_sql "SELECT value FROM ${TABLE_PREFIX}configuration WHERE name='PS_LANG_DEFAULT' LIMIT 1;")"
  [[ -n "$LANG_ID" ]] || { echo "[ERR] Could not detect PS_LANG_DEFAULT"; rm -f "$CNF"; exit 1; }

  echo "[MODE] local"
  echo "[INFO] Output: $DEST"
  echo "[INFO] DB: $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME  prefix=$TABLE_PREFIX  lang=$LANG_ID"

  printf 'SET SESSION group_concat_max_len=8192;\n' | sql_exec >/dev/null

  write_tsv() { # $1=outfile  $2=header ; SQL via STDIN
    local outfile="$1" header="$2"
    printf "%s\n" "$header" > "$outfile"
    sql_exec >> "$outfile"
  }

  # PRODUCTS
  write_tsv "${DEST}/products.tsv" \
"id_product\treference\tname\tprice_tax_excl\tquantity\tactive\tdefault_category\tean13\tupc\tisbn\tvisibility\tdate_add\tdate_upd" <<SQL

SELECT p.id_product, p.reference,
       REPLACE(REPLACE(pl.name, '\t',' '), '\n',' ') AS name,
       p.price, COALESCE(sa.quantity,0), p.active,
       REPLACE(REPLACE(cl.name, '\t',' '), '\n',' ') AS default_category,
       p.ean13, p.upc, p.isbn, p.visibility, p.date_add, p.date_upd
FROM ${TABLE_PREFIX}product p
LEFT JOIN ${TABLE_PREFIX}product_lang pl
       ON pl.id_product=p.id_product AND pl.id_lang=${LANG_ID}
LEFT JOIN ${TABLE_PREFIX}stock_available sa
       ON sa.id_product=p.id_product AND sa.id_product_attribute=0
LEFT JOIN ${TABLE_PREFIX}category_lang cl
       ON cl.id_category=p.id_category_default AND cl.id_lang=${LANG_ID}
ORDER BY p.id_product;
SQL

  # VARIANTS
  write_tsv "${DEST}/variants.tsv" \
"id_product_attribute\tid_product\tcombination\treference\tprice_impact\tweight\tquantity\tean13\tupc" <<SQL

SELECT pa.id_product_attribute, pa.id_product,
       REPLACE(REPLACE(
         GROUP_CONCAT(CONCAT(agl.name, ': ', al.name) ORDER BY agl.name SEPARATOR ', ')
       , '\t',' '), '\n',' ') AS combination,
       pa.reference, COALESCE(pas.price,0), pa.weight, COALESCE(sa.quantity,0), pa.ean13, pa.upc
FROM ${TABLE_PREFIX}product_attribute pa
LEFT JOIN ${TABLE_PREFIX}product_attribute_shop pas
       ON pas.id_product_attribute=pa.id_product_attribute
LEFT JOIN ${TABLE_PREFIX}product_attribute_combination pac
       ON pac.id_product_attribute=pa.id_product_attribute
LEFT JOIN ${TABLE_PREFIX}attribute a ON a.id_attribute=pac.id_attribute
LEFT JOIN ${TABLE_PREFIX}attribute_lang al
       ON al.id_attribute=a.id_attribute AND al.id_lang=${LANG_ID}
LEFT JOIN ${TABLE_PREFIX}attribute_group_lang agl
       ON agl.id_attribute_group=a.id_attribute_group AND agl.id_lang=${LANG_ID}
LEFT JOIN ${TABLE_PREFIX}stock_available sa
       ON sa.id_product_attribute=pa.id_product_attribute
GROUP BY pa.id_product_attribute, pa.id_product, pa.reference, pas.price, pa.weight, sa.quantity, pa.ean13, pa.upc
ORDER BY pa.id_product, pa.id_product_attribute;
SQL

  # CATEGORIES
  write_tsv "${DEST}/categories.tsv" \
"id_category\tname\tid_parent\tactive\tposition" <<SQL

SELECT c.id_category,
       REPLACE(REPLACE(cl.name, '\t',' '), '\n',' ') AS name,
       c.id_parent, c.active, c.position
FROM ${TABLE_PREFIX}category c
JOIN ${TABLE_PREFIX}category_lang cl
     ON cl.id_category=c.id_category AND cl.id_lang=${LANG_ID}
ORDER BY c.id_parent, c.position, c.id_category;
SQL

  # PRODUCT↔CATEGORY
  write_tsv "${DEST}/product_categories.tsv" \
"id_product\tid_category" <<SQL
SELECT id_product, id_category
FROM ${TABLE_PREFIX}category_product
ORDER BY id_product, id_category;
SQL

  # IMAGES MAP
  write_tsv "${DEST}/images.tsv" \
"id_image\tid_product\tcover\tposition" <<SQL
SELECT id_image, id_product, cover, position
FROM ${TABLE_PREFIX}image
ORDER BY id_product, position, id_image;
SQL

  # IMAGES TAR
  if [[ "$INCLUDE_IMAGES" -eq 1 ]]; then
    if [[ -d "$PS_ROOT/img/p" ]]; then
      echo "[STEP] Archiving images from $PS_ROOT/img/p …"
      tar -C "$PS_ROOT/img" -czf "${DEST}/images.tar.gz" p
    else
      echo "[WARN] Images path not found: $PS_ROOT/img/p (skipping)"
    fi
  fi

  rm -f "$CNF"
fi

echo
echo "[OK] Catalog export complete at: $DEST"
wc -l "${DEST}/"*.tsv 2>/dev/null || true
[[ "$INCLUDE_IMAGES" -eq 1 ]] && ls -lh "${DEST}/images.tar.gz" 2>/dev/null || true
