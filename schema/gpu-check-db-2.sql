-- gpu-check-db-version: 2.0.0
--
-- gpu-check database, schema version 2.
--
-- The class of a property belongs to the run and not to the key.  A key
-- that is busy in one run may be quiet in the next, and a class that
-- lived with the key would say that the second run was busy as well.
-- The class moves to a table of its own, with the run in the key.
--
-- The values of a property are already the values of one run: a run
-- keeps its own history, and the values of an earlier run never open the
-- value of this one.

-- The class of a property in one run: constant, changing or counter.  A
-- counter is a gauge that only goes up, so it is left out of "changed"
-- unless it is asked for.
CREATE TABLE property_classes (
    property_id     INTEGER NOT NULL REFERENCES properties(id),
    run_id          INTEGER NOT NULL REFERENCES runs(id),
    classification  TEXT    NOT NULL CHECK (classification IN ('constant',
                                                               'changing',
                                                               'counter')),
    PRIMARY KEY (property_id, run_id)
);

-- The classes that are already there keep the class they had: the class
-- of a key was the class of every run that saw it.
INSERT OR IGNORE INTO property_classes (property_id, run_id, classification)
    SELECT p.id, v.run_id, p.classification
    FROM properties p JOIN property_values v ON v.property_id = p.id;

-- The key no longer holds a class: the class is of the run now.
ALTER TABLE properties DROP COLUMN classification;

CREATE INDEX ix_property_classes_run ON property_classes (run_id, property_id);

-- The value that is open now, for one property of one run.  A snapshot
-- asks for the value of every property of the machine, and the answer
-- must be found and not looked for: without this index the lookup walks
-- the values of the run, and the walk grows with the run.
CREATE INDEX ix_property_values_open_run ON property_values (property_id, run_id)
    WHERE closed_at IS NULL;
