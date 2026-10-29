-- Deploy Sqitch Registry to BigQuery
-- Version 1.1

-- Note: The dataset is created separately with location parameter
-- This file only creates the tables within the dataset

CREATE TABLE IF NOT EXISTS `:registry.releases` (
  version         NUMERIC NOT NULL OPTIONS(description='Version of the Sqitch registry.'),
  installed_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP() OPTIONS(description='Date the registry release was installed.'),
  installer_name  STRING NOT NULL OPTIONS(description='Name of the user who installed the registry release.'),
  installer_email STRING NOT NULL OPTIONS(description='Email address of the user who installed the registry release.'),
  PRIMARY KEY (version) NOT ENFORCED
)
OPTIONS (
      description = 'Sqitch registry releases.'
);

CREATE TABLE IF NOT EXISTS `:registry.projects` (
  project       STRING NOT NULL OPTIONS(description='Unique Name of a project.'),
  uri           STRING OPTIONS(description='Optional project URI.'),
  created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP() OPTIONS(description='Date the project was added to the database.'),
  creator_name  STRING NOT NULL OPTIONS(description='Name of the user who added the project.'),
  creator_email STRING NOT NULL OPTIONS(description='Email address of the user who added the project.'),
  PRIMARY KEY (project) NOT ENFORCED
)
OPTIONS (
    description = 'Sqitch projects deployed to this database.'
);

CREATE TABLE IF NOT EXISTS `:registry.changes` (
  change_id        STRING NOT NULL OPTIONS(description='Change primary key.'),
  script_hash      STRING OPTIONS(description='Deploy script SHA-1 hash.'),
  change           STRING NOT NULL OPTIONS(description='Name of the deployed change.'),
  project          STRING NOT NULL OPTIONS(description='Name of the Sqitch project to which the change belongs.'),
  note             STRING DEFAULT '' OPTIONS(description='Description of the change.'),
  committed_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP() OPTIONS(description='Date the change was deployed.'),
  committer_name   STRING NOT NULL OPTIONS(description='Name of the user who deployed the change.'),
  committer_email  STRING NOT NULL OPTIONS(description='Email address of the user who deployed the change.'),
  planned_at       TIMESTAMP OPTIONS(description='Date the change was added to the plan.'),
  planner_name     STRING OPTIONS(description='Name of the user who planned the change.'),
  planner_email    STRING OPTIONS(description='Email address of the user who planned the change.'),
  PRIMARY KEY (change_id) NOT ENFORCED
)
OPTIONS (
    description = 'Tracks the changes currently deployed to the database.'
);

ALTER TABLE `:registry.changes` ADD CONSTRAINT fk_changes_project FOREIGN KEY (project) REFERENCES `:registry.projects` (project) NOT ENFORCED;

CREATE TABLE IF NOT EXISTS `:registry.tags` (
  tag_id          STRING NOT NULL OPTIONS(description='Tag primary key.'),
  tag             STRING NOT NULL OPTIONS(description='Project-unique tag name.'),
  project         STRING NOT NULL OPTIONS(description='Name of the Sqitch project to which the tag belongs.'),
  change_id       STRING NOT NULL OPTIONS(description='ID of last change deployed before the tag was applied.'),
  note            STRING DEFAULT '' OPTIONS(description='Description of the tag.'),
  committed_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP() OPTIONS(description='Date the tag was applied to the database.'),
  committer_name  STRING NOT NULL OPTIONS(description='Name of the user who applied the tag.'),
  committer_email STRING NOT NULL OPTIONS(description='Email address of the user who applied the tag.'),
  planned_at      TIMESTAMP NOT NULL OPTIONS(description='Date the tag was added to the plan.'),
  planner_name    STRING NOT NULL OPTIONS(description='Name of the user who planned the tag.'),
  planner_email   STRING NOT NULL OPTIONS(description='Email address of the user who planned the tag.'),
  PRIMARY KEY (tag_id) NOT ENFORCED
)
OPTIONS (
    description = 'Tracks the tags currently applied to the database.'
);

ALTER TABLE `:registry.tags` ADD CONSTRAINT fk_tags_project FOREIGN KEY (project) REFERENCES `:registry.projects` (project) NOT ENFORCED;
ALTER TABLE `:registry.tags` ADD CONSTRAINT fk_tags_changes FOREIGN KEY (change_id) REFERENCES `:registry.changes` (change_id) NOT ENFORCED;

CREATE TABLE IF NOT EXISTS `:registry.dependencies` (
  change_id     STRING NOT NULL OPTIONS(description='ID of the depending change.'),
  type          STRING NOT NULL OPTIONS(description='Type of dependency.'),
  dependency    STRING NOT NULL OPTIONS(description='Dependency name.'),
  dependency_id STRING OPTIONS(description='Change ID the dependency resolves to.'),
  PRIMARY KEY (change_id, dependency) NOT ENFORCED
)
OPTIONS (
    description = 'Tracks the currently satisfied dependencies.'
);

ALTER TABLE `:registry.dependencies` ADD CONSTRAINT fk_dependencies_dependency_id FOREIGN KEY (dependency_id) REFERENCES `:registry.changes` (change_id) NOT ENFORCED;

CREATE TABLE IF NOT EXISTS `:registry.events` (
  event           STRING NOT NULL OPTIONS(description='Type of event.'),
  change_id       STRING NOT NULL OPTIONS(description='Change ID.'),
  change          STRING NOT NULL OPTIONS(description='Change name.'),
  project         STRING NOT NULL OPTIONS(description='Name of the Sqitch project to which the change belongs.'),
  note            STRING DEFAULT '' OPTIONS(description='Description of the change.'),
  requires        ARRAY<STRING> OPTIONS(description='Array of the names of required changes'),
  conflicts       ARRAY<STRING> OPTIONS(description='Array of the name of conflicting changes.'),
  tags            ARRAY<STRING> OPTIONS(description='Tags associated with the change.'),
  committed_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP() OPTIONS(description='Date the event was committed.'),
  committer_name  STRING NOT NULL OPTIONS(description='Name of the user who committed the event.'),
  committer_email STRING NOT NULL OPTIONS(description='Email address of the user who committed the event.'),
  planned_at      TIMESTAMP NOT NULL OPTIONS(description='Date the event was added to the plan.'),
  planner_name    STRING NOT NULL OPTIONS(description='Name of the user who planned the change.'),
  planner_email   STRING NOT NULL OPTIONS(description='Email address of the user who planned the change.'),
  PRIMARY KEY (change_id, committed_at) NOT ENFORCED
)
OPTIONS (
  description = 'Contains full story of all deployment events.'
);

ALTER TABLE `:registry.events` ADD CONSTRAINT fk_events_project FOREIGN KEY (project) REFERENCES `:registry.projects` (project) NOT ENFORCED;
