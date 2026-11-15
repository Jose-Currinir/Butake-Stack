#!/bin/bash
# Firma estable de Stack.app, leída con `source` desde build-native.sh.
#
# macOS reconoce una app por su requisito designado. Con firma ad hoc cambia en cada compilación y
# el Llavero vuelve a pedir permiso tras cada actualización. Con una identidad del equipo el
# requisito es siempre el mismo (identificador + certificado de Apple + equipo), así que
# «Permitir siempre» sobrevive a las actualizaciones. Ver docs/operations.md, «Firma».
#
# Identidad, en este orden:
#   1. STACK_SIGN_IDENTITY: huella SHA-1 o nombre de una identidad del llavero; «-» = ad hoc.
#   2. La huella fijada en .stack-sign-identity (local, no versionado), si sigue siendo válida.
#   3. La «Apple Development» válida que vence más tarde (empate: la huella menor); se fija en
#      .stack-sign-identity para que no cambie entre compilaciones.
#   4. Sin ninguna, ad hoc con un aviso.
# Sin derechos (entitlements): ninguno hace falta y algunos exigirían un perfil de aprovisionamiento.

SIGN_PIN="$PROJECT_ROOT/.stack-sign-identity"

# "<huella> <nombre>" de cada identidad de firma válida.
stack_identities() {
    security find-identity -v -p codesigning 2>/dev/null | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "\(.*\)"$/\1 \2/p' | sort -u
}

# Sujeto y vencimiento del certificado con esa huella (sólo la parte pública).
stack_certificate() {
    security find-certificate -a -Z -p 2>/dev/null \
        | awk -v h="$1" '/^SHA-1 hash:/{p=($3==h)} p&&/BEGIN CERT/{c=1} c&&p{print} /END CERT/{c=0}' \
        | openssl x509 -noout -subject -enddate 2>/dev/null
}

stack_resolve_identity() {
    SIGN_SHA=""
    SIGN_TEAM=""
    local wanted="${STACK_SIGN_IDENTITY:-}" list
    list="$(stack_identities)"
    if [ "$wanted" = "-" ]; then
        return
    elif [ -n "$wanted" ]; then
        if [[ "$wanted" =~ ^[0-9A-Fa-f]{40}$ ]]; then
            SIGN_SHA="$(printf '%s' "$wanted" | tr '[:lower:]' '[:upper:]')"
        else
            SIGN_SHA="$(printf '%s\n' "$list" | awk -v n="$wanted" 'substr($0, 42) == n {print $1; exit}')"
        fi
        if [ -z "$SIGN_SHA" ] || ! printf '%s\n' "$list" | grep -q "^$SIGN_SHA "; then
            printf 'Error: STACK_SIGN_IDENTITY («%s») no es una identidad de firma válida del llavero.\n' "$wanted" >&2
            exit 1
        fi
    else
        if [ -f "$SIGN_PIN" ]; then
            local pinned
            pinned="$(tr -d '[:space:]' < "$SIGN_PIN")"
            if printf '%s\n' "$list" | grep -q "^$pinned Apple Development: "; then
                SIGN_SHA="$pinned"
            else
                printf 'Aviso: la identidad fijada en .stack-sign-identity ya no es válida; se elige otra.\n' >&2
            fi
        fi
        if [ -z "$SIGN_SHA" ]; then
            local sha end best=""
            while read -r sha _; do
                end="$(stack_certificate "$sha" | sed -n 's/^notAfter=//p')"
                end="$(date -j -u -f '%b %e %T %Y %Z' "$end" +%s 2>/dev/null || echo 0)"
                best="$best$end $sha"$'\n'
            done < <(printf '%s\n' "$list" | grep ' Apple Development: ')
            SIGN_SHA="$(printf '%s' "$best" | sort -k1,1nr -k2,2 | awk 'NF {print $2; exit}')"
            if [ -n "$SIGN_SHA" ]; then printf '%s\n' "$SIGN_SHA" > "$SIGN_PIN"; fi
        fi
    fi
    if [ -n "$SIGN_SHA" ]; then
        SIGN_TEAM="$(stack_certificate "$SIGN_SHA" | sed -n 's/^subject=.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')"
        SIGN_NAME="$(printf '%s\n' "$list" | awk -v h="$SIGN_SHA" '$1 == h {print substr($0, 42); exit}')"
    fi
}

# stack_sign <ruta> <identificador>
stack_sign() {
    if [ -z "$SIGN_SHA" ]; then
        codesign --force --sign - --identifier "$2" "$1"
    elif [ -n "$SIGN_TEAM" ]; then
        codesign --force --timestamp=none --sign "$SIGN_SHA" --identifier "$2" \
            "-r=designated => identifier \"$2\" and anchor apple generic and certificate leaf[subject.OU] = \"$SIGN_TEAM\"" "$1"
    else
        codesign --force --timestamp=none --sign "$SIGN_SHA" --identifier "$2" "$1"
    fi
}

stack_resolve_identity
if [ -n "$SIGN_SHA" ]; then
    printf 'Firma: %s (%s, equipo %s)\n' "$SIGN_NAME" "$SIGN_SHA" "${SIGN_TEAM:-?}" >&2
elif [ "${STACK_SIGN_IDENTITY:-}" = "-" ]; then
    printf 'Firma: ad hoc (STACK_SIGN_IDENTITY=-). El Llavero volverá a pedir permiso tras cada compilación.\n' >&2
else
    printf 'Aviso: no hay una identidad «Apple Development» válida en el llavero; firma ad hoc.\n' >&2
    printf '       El Llavero volverá a pedir permiso tras cada compilación (ver docs/operations.md, «Firma»).\n' >&2
fi
