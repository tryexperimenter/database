/*View information about tables in database.*/

SELECT *
FROM information_schema.columns
WHERE table_schema = 'public';

--Drop table if exists
DROP TABLE IF EXISTS experiments;







/***
Create experiments table.

Purpose: store all available experiments.
***/

CREATE TABLE experiments(
	id UUID DEFAULT uuid_generate_v4(),
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	name VARCHAR NOT NULL,
	description VARCHAR NOT NULL,
	active BOOLEAN NOT NULL DEFAULT TRUE,
	PRIMARY KEY (id)
);

--Each experiment.name has to be unique
CREATE UNIQUE INDEX experiment_name_unique_index
	ON experiments (name);

--Automatically update updated_time.
CREATE TRIGGER experiments_set_updated_time
BEFORE UPDATE ON experiments
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();

/***

Create experiment_preferences table.

Purpose: store current and previous preferences for regarding experiments.
***/

CREATE TABLE experiment_preferences(
	id UUID DEFAULT uuid_generate_v4(),
	user_id UUID,
	created_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	active BOOLEAN NOT NULL DEFAULT TRUE,
	PRIMARY KEY (id),
	CONSTRAINT fk_users --a preference has to be associated with a user
		FOREIGN KEY(user_id)
			REFERENCES users(id)
);

--Each user_id can only have one active preference
CREATE UNIQUE INDEX user_id_has_one_active_experiment_preference_index
	ON experiment_preferences (user_id) WHERE active = TRUE;
	
--Automatically update updated_time.
CREATE TRIGGER experiment_preferences_set_updated_time
BEFORE UPDATE ON experiment_preferences
FOR EACH ROW
EXECUTE PROCEDURE trigger_set_updated_time();

--Test that each user_id can only have one active preference
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

--Try to insert the same user again 
/*Should fail as experiment_preferences.active defaults to TRUE and violates each 
user_id can only have one active preference*/
WITH new_rows(user_email) AS
(VALUES
	('tristanzucker@gmail.com') 
)  
INSERT INTO experiment_preferences(user_id) 
SELECT users.id
FROM users
	JOIN new_rows n
	ON users.email = n.user_email;
	
--Try to insert the same user again but with active = FALSE so that it doesn't violate constraint
WITH new_rows(user_email, active) AS
(VALUES
	('tristanzucker@gmail.com', FALSE) 
)  
INSERT INTO experiment_preferences(user_id, active) 
SELECT users.id, n.active
FROM users
	JOIN new_rows n
	ON users.email = n.user_email;
	
--Check that everything worked
SELECT * FROM experiment_preferences;