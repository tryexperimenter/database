/*View information about tables in database.*/

SELECT *
FROM information_schema.columns
WHERE table_schema = 'public';

--Drop table if exists
DROP TABLE IF EXISTS experiments;