/*
Version: 1.0
Author: Tuan Pham
Date: 04/30/2026.
Description: Federated script synchronizes the data from Spanner to BigQuery.
Tables: AuthorizationsClientLine, StoreGroups, StoreGroupsYoYChanges, Stores, StoresToMerchantIdsAuthorization, StoresToStoreGroups
*/
CREATE OR REPLACE TABLE `project-3d127dc4-8358-46e9-b7e.backfill_dataset.AuthorizationsClientLine`
PARTITION BY DATE(timestamp)
CLUSTER BY siteIdFrontEnd, terminalId, type, isNewAtStore  
AS
SELECT * FROM EXTERNAL_QUERY(
 "projects/project-3d127dc4-8358-46e9-b7e/locations/us-central1/connections/spanner-connection",
 "SELECT * FROM AuthorizationsClientLine"
);
CREATE OR REPLACE TABLE `project-3d127dc4-8358-46e9-b7e.backfill_dataset.StoreGroups` 
AS
SELECT * FROM EXTERNAL_QUERY(
 "projects/project-3d127dc4-8358-46e9-b7e/locations/us-central1/connections/spanner-connection",
 "SELECT * FROM StoreGroups"
);
CREATE OR REPLACE TABLE `project-3d127dc4-8358-46e9-b7e.backfill_dataset.StoreGroupsYoYChanges` 
AS
SELECT * FROM EXTERNAL_QUERY(
 "projects/project-3d127dc4-8358-46e9-b7e/locations/us-central1/connections/spanner-connection",
 "SELECT * FROM StoreGroupsYoYChanges"
);
CREATE OR REPLACE TABLE `project-3d127dc4-8358-46e9-b7e.backfill_dataset.Stores` 
AS
SELECT * FROM EXTERNAL_QUERY(
 "projects/project-3d127dc4-8358-46e9-b7e/locations/us-central1/connections/spanner-connection",
 "SELECT * FROM Stores"
);
CREATE OR REPLACE TABLE `project-3d127dc4-8358-46e9-b7e.backfill_dataset.StoresToMerchantIdsAuthorization`
AS
SELECT * FROM EXTERNAL_QUERY(
 "projects/project-3d127dc4-8358-46e9-b7e/locations/us-central1/connections/spanner-connection",
 "SELECT * FROM StoresToMerchantIdsAuthorization"
);
CREATE OR REPLACE TABLE `project-3d127dc4-8358-46e9-b7e.backfill_dataset.StoresToStoreGroups`
AS
SELECT * FROM EXTERNAL_QUERY(
 "projects/project-3d127dc4-8358-46e9-b7e/locations/us-central1/connections/spanner-connection",
 "SELECT * FROM StoresToStoreGroups"
);
