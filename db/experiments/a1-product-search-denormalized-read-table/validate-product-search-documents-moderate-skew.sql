\set ON_ERROR_STOP on
\timing on
\pset pager off

-- Manual validate-all wrapper for product_search_documents_moderate_skew.
--
-- The PowerShell runner does not use this file for the default action. It runs
-- section-specific SQL files for section-level artifacts and isolation.
-- Execute this wrapper only when running every validation section is intended.

\ir validate-product-search-documents-moderate-skew-cheap.sql
\ir validate-product-search-documents-moderate-skew-product-id-set.sql
\ir validate-product-search-documents-moderate-skew-signature-count.sql
\ir validate-product-search-documents-moderate-skew-equivalence-b1.sql
\ir validate-product-search-documents-moderate-skew-equivalence-b2.sql
\ir validate-product-search-documents-moderate-skew-equivalence-b3.sql
