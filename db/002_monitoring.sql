BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'prometheus') THEN
        CREATE ROLE prometheus LOGIN;
    END IF;
END
$$;

GRANT pg_monitor TO prometheus;
GRANT CONNECT ON DATABASE inventory TO prometheus;

COMMIT;
