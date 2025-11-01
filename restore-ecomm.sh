#!/usr/bin/env bash
# restore-ecomm.sh — Restore PrestaShop catalog from TSV + images (Docker OR local).
# - Docker mode: copies TSVs into DB container secure_file_priv and uses LOAD DATA INFILE
# - Local mode: requires mysql/mariadb client and uses LOAD DATA LOCAL INFILE
# This restores by UPDATE/UPSERT into existing records. It does NOT recreate missing rows.

set -euo pipefail

MODE="auto"                                       # auto | docker | local
APP_CTN="${APP_CTN:-prestashop-prestashop-1}"
DB_CTN="${DB_CTN:-prestashop-db-1}"
PS_ROOT="${PS_ROOT:-/var/www/html}"               # local mode PS root
SRC_DIR=""                                        # --from <dir>
NO_IMAGES=0
LANG_ID=""
DB_HOST="" DB_PORT="" DB_NAME="" DB_USER="" DB_PASS="" DB_PREFIX=""

usage() {
  cat <<EOF
Usage: sudo $0 --from /opt/backups/prestashop-catalog/export-YYYYmmddTHHMMSSZ [options]

Required:
  --from DIR          Path to the export directory (with products.tsv, ...)

Optional:
  --docker            Force Docker mode
  --local             Force local mode (non-Docker)
  --app NAME          App container (default: $APP_CTN)
  --db NAME           DB container (default: $DB_CTN)
  --root DIR          PrestaShop root (local mode; default: $PS_ROOT)
  --no-images         Do not extract images.tar.gz
  --lang ID           Force language id (default: auto PS_LANG_DEFAULT)
  --db-host HOST      Local mode: DB host
  --db-port PORT      Local mode: DB port (default: 3306)
  --db-name NAME      Local mode: DB name
  --db-user USER      Local mode: DB user
  --db-pass PASS      Local mode: DB password
  --db-prefix ps_     Table prefix override (default: auto)
  -h|--help           Show help
EOF
}

[[ $# -gt 0 ]] || { usage; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) SRC_DIR="$2"; shift 2;;
    --docker) MODE="docker"; shift;;
    --local)  MODE="local"; shift;;
    --app)    APP_CTN="$2"; shift 2;;
    --db)     DB_CTN="$2"; shift 2;;
    --root)   PS_ROOT="$2"; shift 2;;
    --no-images) NO_IMAGES=1; shift;;
    --lang)   LANG_ID="$2"; shift 2;;
    --db-host) DB_HOST="$2"; shift 2;;
    --db-port) DB_PORT="$2"; shift 2;;
    --db-name) DB_NAME="$2"; shift 2;;
    --db-user) DB_USER="$2"; shift 2;;
    --db-pass) DB_PASS="$2"; shift 2;;
    --db-prefix) DB_PREFIX="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "[ERR] Unknown option: $1"; usage; exit 1;;
  esac
done

[[ -d "$SRC_DIR" ]] || { echo "[ERR] Export directory not found: $SRC_DIR"; exit 1; }
for f in products.tsv variants.tsv categories.tsv product_categories.tsv images.tsv; do
  [[ -f "$SRC_DIR/$f" ]] || { echo "[ERR] Missing $f in $SRC_DIR"; exit 1; }
done

have(){ command -v "$1" >/dev/null 2>&1; }

# Decide mode
if [[ "$MODE" == "auto" ]]; then
  if have docker && docker ps --format '{{.Names}}' | grep -Eq "^(${APP_CTN}|${DB_CTN})$"; then
    MODE="docker"
  else
    MODE="local"
  fi
fi

# ====== Shared SQL body (uses: DB_PREFIX, LANG_ID, SHOP_ID, SHOP_GRP, paths) ======
mk_sql_updates() {
cat <<EOSQL
SET FOREIGN_KEY_CHECKS=0;
START TRANSACTION;
SET SESSION group_concat_max_len=8192;

DROP TEMPORARY TABLE IF EXISTS _t_products, _t_variants, _t_categories, _t_prodcat, _t_images;

CREATE TEMPORARY TABLE _t_products (
  id_product INT PRIMARY KEY,
  reference VARCHAR(64), name TEXT,
  price_tax_excl DECIMAL(20,6),
  quantity INT, active TINYINT,
  default_category VARCHAR(255),
  ean13 VARCHAR(13), upc VARCHAR(12), isbn VARCHAR(32),
  visibility VARCHAR(10),
  date_add DATETIME, date_upd DATETIME
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TEMPORARY TABLE _t_variants (
  id_product_attribute INT PRIMARY KEY,
  id_product INT,
  combination TEXT,
  reference VARCHAR(64),
  price_impact DECIMAL(20,6),
  weight DECIMAL(20,6),
  quantity INT,
  ean13 VARCHAR(13), upc VARCHAR(12)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TEMPORARY TABLE _t_categories (
  id_category INT PRIMARY KEY,
  name VARCHAR(255),
  id_parent INT,
  active TINYINT,
  position INT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TEMPORARY TABLE _t_prodcat (
  id_product INT,
  id_category INT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TEMPORARY TABLE _t_images (
  id_image INT PRIMARY KEY,
  id_product INT,
  cover TINYINT,
  position INT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

/* LOAD TSVs */
-- (placeholders replaced by caller)
-- @@LOAD_PRODUCTS@@
-- @@LOAD_VARIANTS@@
-- @@LOAD_CATEGORIES@@
-- @@LOAD_PRODCAT@@
-- @@LOAD_IMAGES@@

/* PRODUCTS core fields */
UPDATE ${DB_PREFIX}product p
JOIN _t_products t ON t.id_product=p.id_product
SET p.reference = COALESCE(t.reference,p.reference),
    p.price     = COALESCE(t.price_tax_excl,p.price),
    p.active    = COALESCE(t.active,p.active),
    p.ean13     = COALESCE(t.ean13,p.ean13),
    p.upc       = COALESCE(t.upc,p.upc),
    p.isbn      = COALESCE(t.isbn,p.isbn),
    p.visibility= COALESCE(t.visibility,p.visibility);

/* product_shop mirrors */
UPDATE ${DB_PREFIX}product_shop ps
JOIN _t_products t ON t.id_product=ps.id_product AND ps.id_shop=${SHOP_ID}
SET ps.price  = COALESCE(t.price_tax_excl, ps.price),
    ps.active = COALESCE(t.active, ps.active);

/* product_lang: name (if row exists) */
UPDATE ${DB_PREFIX}product_lang pl
JOIN _t_products t ON t.id_product=pl.id_product
SET pl.name = t.name
WHERE pl.id_lang=${LANG_ID} AND pl.id_shop=${SHOP_ID};

/* default category (resolve by name if provided) */
UPDATE ${DB_PREFIX}product p
JOIN _t_products t ON t.id_product=p.id_product
LEFT JOIN ${DB_PREFIX}category_lang cl
  ON cl.name=t.default_category AND cl.id_lang=${LANG_ID}
SET p.id_category_default = COALESCE(cl.id_category, p.id_category_default);

/* stock (base product) */
INSERT INTO ${DB_PREFIX}stock_available (id_product,id_product_attribute,id_shop,id_shop_group,quantity)
SELECT t.id_product, 0, ${SHOP_ID}, ${SHOP_GRP}, COALESCE(t.quantity,0)
FROM _t_products t
ON DUPLICATE KEY UPDATE quantity=VALUES(quantity);

/* categories */
UPDATE ${DB_PREFIX}category c
JOIN _t_categories t ON t.id_category=c.id_category
SET c.id_parent = COALESCE(t.id_parent,c.id_parent),
    c.active    = COALESCE(t.active,c.active),
    c.position  = COALESCE(t.position,c.position);

UPDATE ${DB_PREFIX}category_lang cl
JOIN _t_categories t ON t.id_category=cl.id_category
SET cl.name=t.name
WHERE cl.id_lang=${LANG_ID} AND cl.id_shop=${SHOP_ID};

/* product↔category: replace for the exported product set */
DELETE cp FROM ${DB_PREFIX}category_product cp
JOIN (SELECT DISTINCT id_product FROM _t_prodcat) x USING (id_product);

INSERT IGNORE INTO ${DB_PREFIX}category_product (id_category,id_product,position)
SELECT p.id_category, p.id_product,
       ROW_NUMBER() OVER (PARTITION BY p.id_category ORDER BY p.id_product)
FROM _t_prodcat p;

/* variants simple fields */
UPDATE ${DB_PREFIX}product_attribute pa
JOIN _t_variants t ON t.id_product_attribute=pa.id_product_attribute
SET pa.reference = COALESCE(t.reference, pa.reference),
    pa.weight    = COALESCE(t.weight, pa.weight),
    pa.ean13     = COALESCE(t.ean13, pa.ean13),
    pa.upc       = COALESCE(t.upc, pa.upc);

UPDATE ${DB_PREFIX}product_attribute_shop pas
JOIN _t_variants t ON t.id_product_attribute=pas.id_product_attribute
SET pas.price = COALESCE(t.price_impact, pas.price)
WHERE pas.id_shop=${SHOP_ID};

/* variant stock */
INSERT INTO ${DB_PREFIX}stock_available (id_product,id_product_attribute,id_shop,id_shop_group,quantity)
SELECT t.id_product, t.id_product_attribute, ${SHOP_ID}, ${SHOP_GRP}, COALESCE(t.quantity,0)
FROM _t_variants t
ON DUPLICATE KEY UPDATE quantity=VALUES(quantity);

/* images meta */
UPDATE ${DB_PREFIX}image i
JOIN _t_images t ON t.id_image=i.id_image
SET i.position=COALESCE(t.position, i.position);

UPDATE ${DB_PREFIX}image_shop ishp
JOIN _t_images t ON t.id_image=ishp.id_image
SET ishp.cover=COALESCE(t.cover, ishp.cover)
WHERE ishp.id_shop=${SHOP_ID};

COMMIT;
SET FOREIGN_KEY_CHECKS=1;
EOSQL
}

# ====== Docker mode ======
if [[ "$MODE" == "docker" ]]; then
  command -v docker >/dev/null || { echo "[ERR] docker not found"; exit 1; }

  APP_ID="$(docker ps -q -f "name=^/${APP_CTN}$")"
  DB_ID="$(docker ps -q -f "name=^/${DB_CTN}$")"
  [[ -n "$APP_ID" ]] || { echo "[ERR] App container '$APP_CTN' not running"; exit 1; }
  [[ -n "$DB_ID"  ]] || { echo "[ERR] DB container '$DB_CTN' not running"; exit 1; }

  # DB creds
  read -r DB_NAME DB_USER DB_PASS < <(docker exec "$APP_ID" sh -lc \
    'printf "%s %s %s\n" "${DB_NAME:-prestashop}" "${DB_USER:-pshop}" "${DB_PASSWD:-changeme_db}"')
  if [[ -z "$DB_NAME$DB_USER$DB_PASS" || "$DB_NAME" = " " ]]; then
    read -r DB_NAME DB_USER DB_PASS < <(docker exec "$DB_ID" sh -lc \
      'printf "%s %s %s\n" "${MYSQL_DATABASE:-prestashop}" "${MYSQL_USER:-pshop}" "${MYSQL_PASSWORD:-changeme_db}"')
  fi
  DBCLI="$(docker exec "$DB_ID" sh -lc 'command -v mariadb >/dev/null && echo mariadb || echo mysql')"

  sql(){ printf "%s" "$1" | docker exec -i "$DB_ID" sh -lc "$DBCLI -N -B -u'${DB_USER}' -p'${DB_PASS}' '${DB_NAME}'"; }

  # Detect prefix, lang, shop ids
  [[ -n "$DB_PREFIX" ]] || DB_PREFIX="$(sql "SELECT COALESCE(SUBSTRING_INDEX(table_name,'product',1),'ps_') FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name LIKE '%product' LIMIT 1;")"
  [[ -n "$DB_PREFIX" ]] || DB_PREFIX="ps_"
  [[ -n "$LANG_ID"   ]] || LANG_ID="$(sql "SELECT value FROM ${DB_PREFIX}configuration WHERE name='PS_LANG_DEFAULT' LIMIT 1;")"
  SHOP_ID="$(sql "SELECT COALESCE(MIN(id_shop),1) FROM ${DB_PREFIX}shop;")"
  SHOP_GRP="$(sql "SELECT COALESCE(MIN(id_shop_group),1) FROM ${DB_PREFIX}shop;")"

  echo "[MODE] docker"
  echo "[INFO] DB=${DB_NAME} user=${DB_USER} prefix=${DB_PREFIX} lang=${LANG_ID} shop=${SHOP_ID}/${SHOP_GRP}"

  # Find secure_file_priv (server-side import path)
  SFP="$(sql "SHOW VARIABLES LIKE 'secure_file_priv';" | awk '{print $2}')"
  if [[ -z "$SFP" ]]; then SFP="/tmp/"; fi
  SFP="${SFP%/}/"  # ensure trailing slash

  # Copy TSVs into the DB container secure path
  for f in products.tsv variants.tsv categories.tsv product_categories.tsv images.tsv; do
    docker cp "${SRC_DIR}/${f}" "${DB_ID}:${SFP}${f}"
  done

  # Build LOAD DATA INFILE statements (server-side path)
  LOAD_PRODUCTS="LOAD DATA INFILE '${SFP}products.tsv' INTO TABLE _t_products CHARACTER SET utf8mb4 FIELDS TERMINATED BY 0x09 LINES TERMINATED BY 0x0A IGNORE 1 LINES;"
  LOAD_VARIANTS="LOAD DATA INFILE '${SFP}variants.tsv' INTO TABLE _t_variants CHARACTER SET utf8mb4 FIELDS TERMINATED BY 0x09 LINES TERMINATED BY 0x0A IGNORE 1 LINES;"
  LOAD_CATEGORIES="LOAD DATA INFILE '${SFP}categories.tsv' INTO TABLE _t_categories CHARACTER SET utf8mb4 FIELDS TERMINATED BY 0x09 LINES TERMINATED BY 0x0A IGNORE 1 LINES;"
  LOAD_PRODCAT="LOAD DATA INFILE '${SFP}product_categories.tsv' INTO TABLE _t_prodcat CHARACTER SET utf8mb4 FIELDS TERMINATED BY 0x09 LINES TERMINATED BY 0x0A IGNORE 1 LINES;"
  LOAD_IMAGES="LOAD DATA INFILE '${SFP}images.tsv' INTO TABLE _t_images CHARACTER SET utf8mb4 FIELDS TERMINATED BY 0x09 LINES TERMINATED BY 0x0A IGNORE 1 LINES;"

  # Produce SQL with placeholders replaced
  SQL_FILE="$(mktemp)"
  SHOP_ID="$SHOP_ID" SHOP_GRP="$SHOP_GRP" LANG_ID="$LANG_ID" DB_PREFIX="$DB_PREFIX" \
  mk_sql_updates | sed \
    -e "s|@@LOAD_PRODUCTS@@|${LOAD_PRODUCTS//|/\\|}|" \
    -e "s|@@LOAD_VARIANTS@@|${LOAD_VARIANTS//|/\\|}|" \
    -e "s|@@LOAD_CATEGORIES@@|${LOAD_CATEGORIES//|/\\|}|" \
    -e "s|@@LOAD_PRODCAT@@|${LOAD_PRODCAT//|/\\|}|" \
    -e "s|@@LOAD_IMAGES@@|${LOAD_IMAGES//|/\\|}|" > "$SQL_FILE"

  # Execute SQL
  docker exec -i "$DB_ID" sh -lc "$DBCLI -u'${DB_USER}' -p'${DB_PASS}' '${DB_NAME}'" < "$SQL_FILE"

  # Optional: images
  if [[ $NO_IMAGES -eq 0 && -f "$SRC_DIR/images.tar.gz" ]]; then
    echo "[STEP] Restoring images into app container (${APP_CTN}) ..."
    docker exec -i "$APP_ID" sh -lc "tar -C /var/www/html/img -xzf - && \
      (id -u www-data >/dev/null 2>&1 && chown -R www-data:www-data /var/www/html/img/p || true)" < "$SRC_DIR/images.tar.gz"
  fi

  # Cleanup copied TSVs
  for f in products.tsv variants.tsv categories.tsv product_categories.tsv images.tsv; do
    docker exec "$DB_ID" sh -lc "rm -f '${SFP}${f}'" || true
  done

  rm -f "$SQL_FILE"
  echo "[OK] Catalog restore completed (Docker). Review a few items in Back Office."

# ====== Local mode ======
else
  # Need local client
  if have mariadb; then MYSQL_BIN="mariadb"; elif have mysql; then MYSQL_BIN="mysql"; else
    echo "[ERR] Need mysql or mariadb client."; exit 1
  fi

  P6="$PS_ROOT/config/settings.inc.php"
  P8="$PS_ROOT/app/config/parameters.php"

  if [[ -z "$DB_NAME$DB_USER$DB_PASS$DB_HOST$DB_PREFIX" ]]; then
    if [[ -f "$P8" ]] && have php; then
      IFS=" " read -r DB_HOST DB_PORT DB_NAME DB_USER DB_PASS DB_PREFIX < <(
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
      DB_PREFIX="$(grep -Po "database_prefix'\s*=>\s*'[^']*" "$P8" | sed "s/.*'//" || echo ps_)"
    elif [[ -f "$P6" ]]; then
      DB_HOST="$(grep -Po "define\('_DB_SERVER_',\s*'[^']*" "$P6" | sed "s/.*'//")"
      DB_PORT="3306"
      DB_NAME="$(grep -Po "define\('_DB_NAME_',\s*'[^']*" "$P6" | sed "s/.*'//")"
      DB_USER="$(grep -Po "define\('_DB_USER_',\s*'[^']*" "$P6" | sed "s/.*'//")"
      DB_PASS="$(grep -Po "define\('_DB_PASSWD_',\s*'[^']*" "$P6" | sed "s/.*'//")"
      DB_PREFIX="$(grep -Po "define\('_DB_PREFIX_',\s*'[^']*" "$P6" | sed "s/.*'//")"
    else
      echo "[ERR] Could not determine DB creds; pass --db-* flags."
      exit 1
    fi
  fi
  DB_PORT="${DB_PORT:-3306}"
  DB_PREFIX="${DB_PREFIX:-ps_}"
  [[ -n "$LANG_ID" ]] || LANG_ID="$("$MYSQL_BIN" -N -B -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e \
    "SELECT value FROM ${DB_PREFIX}configuration WHERE name='PS_LANG_DEFAULT' LIMIT 1;")"
  SHOP_ID="$("$MYSQL_BIN" -N -B -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e \
    "SELECT COALESCE(MIN(id_shop),1) FROM ${DB_PREFIX}shop;")"
  SHOP_GRP="$("$MYSQL_BIN" -N -B -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e \
    "SELECT COALESCE(MIN(id_shop_group),1) FROM ${DB_PREFIX}shop;")"

  # Build loader statements for LOCAL INFILE (host files)
  LOAD_PRODUCTS="LOAD DATA LOCAL INFILE '$(realpath "$SRC_DIR/products.tsv")' INTO TABLE _t_products CHARACTER SET utf8mb4 FIELDS TERMINATED BY 0x09 LINES TERMINATED BY 0x0A IGNORE 1 LINES;"
  LOAD_VARIANTS="LOAD DATA LOCAL INFILE '$(realpath "$SRC_DIR/variants.tsv")' INTO TABLE _t_variants CHARACTER SET utf8mb4 FIELDS TERMINATED BY 0x09 LINES TERMINATED BY 0x0A IGNORE 1 LINES;"
  LOAD_CATEGORIES="LOAD DATA LOCAL INFILE '$(realpath "$SRC_DIR/categories.tsv")' INTO TABLE _t_categories CHARACTER SET utf8mb4 FIELDS TERMINATED BY 0x09 LINES TERMINATED BY 0x0A IGNORE 1 LINES;"
  LOAD_PRODCAT="LOAD DATA LOCAL INFILE '$(realpath "$SRC_DIR/product_categories.tsv")' INTO TABLE _t_prodcat CHARACTER SET utf8mb4 FIELDS TERMINATED BY 0x09 LINES TERMINATED BY 0x0A IGNORE 1 LINES;"
  LOAD_IMAGES="LOAD DATA LOCAL INFILE '$(realpath "$SRC_DIR/images.tsv")' INTO TABLE _t_images CHARACTER SET utf8mb4 FIELDS TERMINATED BY 0x09 LINES TERMINATED BY 0x0A IGNORE 1 LINES;"

  SQL_FILE="$(mktemp)"
  SHOP_ID="$SHOP_ID" SHOP_GRP="$SHOP_GRP" LANG_ID="$LANG_ID" DB_PREFIX="$DB_PREFIX" \
  mk_sql_updates | sed \
    -e "s|@@LOAD_PRODUCTS@@|${LOAD_PRODUCTS//|/\\|}|" \
    -e "s|@@LOAD_VARIANTS@@|${LOAD_VARIANTS//|/\\|}|" \
    -e "s|@@LOAD_CATEGORIES@@|${LOAD_CATEGORIES//|/\\|}|" \
    -e "s|@@LOAD_PRODCAT@@|${LOAD_PRODCAT//|/\\|}|" \
    -e "s|@@LOAD_IMAGES@@|${LOAD_IMAGES//|/\\|}|" > "$SQL_FILE"

  "$MYSQL_BIN" --local-infile=1 -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$SQL_FILE"

  if [[ $NO_IMAGES -eq 0 && -f "$SRC_DIR/images.tar.gz" ]]; then
    echo "[STEP] Restoring images into $PS_ROOT/img ..."
    tar -C "$PS_ROOT/img" -xzf "$SRC_DIR/images.tar.gz"
    if id -u www-data >/dev/null 2>&1; then chown -R www-data:www-data "$PS_ROOT/img/p" || true; fi
  fi

  rm -f "$SQL_FILE"
  echo "[OK] Catalog restore completed (local)."
fi
