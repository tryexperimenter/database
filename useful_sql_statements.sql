/*Also see Database Statements:

https://docs.google.com/spreadsheets/d/1iGiOpZwZhzZG_NXiDi541MWtHguC-ycCUzIvhPthjSk/edit#gid=0
*/


/*View information about tables in database.*/

SELECT *
FROM information_schema.columns
WHERE table_schema = 'public';

--Drop table if exists
DROP TABLE IF EXISTS experiments;


--Select all rows that have "" in email_body
SELECT *
FROM sub_group_action_templates
WHERE email_body LIKE '%""%';

--Replace every instance of "" with " in email_body for all rows
UPDATE sub_group_action_templates
SET email_body = REPLACE(email_body, '""', '"');




--Create temporary table to use for an insert
WITH new_rows(user_email) AS
(VALUES
	('tristanzucker@gmail.com') ,
	('tristanandrewzucker@gmail.com')
)  
INSERT INTO experiment_preferences(user_id) 
SELECT users.id
FROM users
	JOIN new_rows n
	ON users.email = n.user_email;
