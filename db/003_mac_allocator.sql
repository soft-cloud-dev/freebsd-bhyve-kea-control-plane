BEGIN;

CREATE OR REPLACE FUNCTION allocate_mac(
    p_namespace TEXT,
    p_vm_name TEXT
) RETURNS MACADDR AS $$
DECLARE
    attempt INTEGER;
    digest TEXT;
    candidate MACADDR;
BEGIN
    IF p_namespace IS NULL OR btrim(p_namespace) = '' THEN
        RAISE EXCEPTION 'MAC allocation namespace must not be empty';
    END IF;

    IF p_vm_name IS NULL OR btrim(p_vm_name) = '' THEN
        RAISE EXCEPTION 'VM name must not be empty';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('control-plane-mac-allocation-v1'));

    FOR attempt IN 0..1023 LOOP
        digest := md5(
            length(p_namespace)::TEXT || ':' || p_namespace || ':' ||
            length(p_vm_name)::TEXT || ':' || p_vm_name || ':' ||
            attempt::TEXT
        );

        candidate := (
            '02:' ||
            substr(digest, 1, 2) || ':' ||
            substr(digest, 3, 2) || ':' ||
            substr(digest, 5, 2) || ':' ||
            substr(digest, 7, 2) || ':' ||
            substr(digest, 9, 2)
        )::MACADDR;

        IF NOT EXISTS (
            SELECT 1
              FROM vms
             WHERE mac_address = candidate
               AND status <> 'archived'
        ) THEN
            RETURN candidate;
        END IF;
    END LOOP;

    RAISE EXCEPTION 'unable to allocate a unique MAC address for namespace % and VM %',
        p_namespace, p_vm_name;
END;
$$ LANGUAGE plpgsql;

COMMIT;
