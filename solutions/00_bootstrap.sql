-- =====================================================================
-- 00_bootstrap.sql  (RUN ONCE in Snowsight as the event account's ACCOUNTADMIN)
-- Identity ONLY: creates the VHOLuser login + PAT that CoCo Desktop uses.
-- CoCo can't create its own login, so this runs first. Everything else —
-- roles, warehouse, Postgres, Openflow, Iceberg, agent — you build by
-- prompting CoCo (see README).
--
-- HOW TO RUN: highlight one block and run it (Cmd/Ctrl+Enter).
-- =====================================================================

-- ============================ BLOCK 1: identity + PAT ============================
USE ROLE ACCOUNTADMIN;

CREATE USER IF NOT EXISTS VHOLuser
  DEFAULT_ROLE = ACCOUNTADMIN
  DEFAULT_SECONDARY_ROLES = ('ALL')
  COMMENT = 'Openflow Retail VHOL lab user';
GRANT ROLE ACCOUNTADMIN TO USER VHOLuser;

-- PATs require the user to be under a network policy, so open a permissive one (lab only).
CREATE NETWORK POLICY IF NOT EXISTS vhol_np ALLOWED_IP_LIST = ('0.0.0.0/0');
ALTER USER VHOLuser SET NETWORK_POLICY = vhol_np;

ALTER USER VHOLuser
  ADD PROGRAMMATIC ACCESS TOKEN vhol_pat
    ROLE_RESTRICTION = 'ACCOUNTADMIN'
    DAYS_TO_EXPIRY = 7
    COMMENT = 'Openflow Retail VHOL lab token';
-- >>> Copy the token_secret value now (shown once). Paste it into CoCo Desktop's connection. <<<

-- ============================ BLOCK 2: account identifier ============================
SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS account_identifier;

-- ============================ OPTIONAL: teardown (run later from Snowsight, NOT CoCo) ============================
-- ALTER USER VHOLuser REMOVE PROGRAMMATIC ACCESS TOKEN vhol_pat;
-- DROP USER IF EXISTS VHOLuser;
-- DROP NETWORK POLICY IF EXISTS vhol_np;
