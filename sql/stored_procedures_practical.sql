-- =====================================================================
-- ST0525 Practical - Stored Procedures & User Defined Functions
-- Database: highgarden_university (PostgreSQL 18, port 5433)
-- =====================================================================


-- =====================================================================
-- Section A: Create Stored Procedures
-- =====================================================================

-- create module stored procedure
-- Raises an error (SQLSTATE P0001) if the module already exists
CREATE OR REPLACE PROCEDURE create_module(IN p_code VARCHAR(10), IN p_name VARCHAR(100), IN p_credit INT)
AS $$
BEGIN
    -- Check if the module already exists
    IF EXISTS (SELECT * FROM module WHERE mod_code = p_code) THEN
        RAISE EXCEPTION 'Module % already exists', p_code;
    END IF;

    -- Insert the new module
    INSERT INTO module (mod_code, mod_name, credit_unit) VALUES (p_code, p_name, p_credit);
END;
$$ LANGUAGE plpgsql;


-- update module stored procedure
-- Raises an error (SQLSTATE P0001) if the module is not found
CREATE OR REPLACE PROCEDURE update_module(IN p_code VARCHAR(10), IN p_credit INT)
AS $$
BEGIN
    -- Raise an error if the module is NOT found
    IF NOT EXISTS (SELECT * FROM module WHERE mod_code = p_code) THEN
        RAISE EXCEPTION 'Module % not found', p_code;
    END IF;

    -- Update the module's credit unit
    UPDATE module SET credit_unit = p_credit WHERE mod_code = p_code;
END;
$$ LANGUAGE plpgsql;


-- delete module stored procedure
-- Raises an error (SQLSTATE P0001) if the module is not found
CREATE OR REPLACE PROCEDURE delete_module(IN p_code VARCHAR(10))
AS $$
BEGIN
    -- Raise an error if the module is NOT found
    IF NOT EXISTS (SELECT * FROM module WHERE mod_code = p_code) THEN
        RAISE EXCEPTION 'Module % not found', p_code;
    END IF;

    -- Delete the module
    DELETE FROM module WHERE mod_code = p_code;
END;
$$ LANGUAGE plpgsql;

-- Test (invoked with CALL):
-- CALL create_module('ST0525', 'DBS', 6);
-- CALL update_module('ST0525', 5);
-- CALL delete_module('ST0525');


-- =====================================================================
-- Section B: User Defined Database Function
-- =====================================================================

-- Q1: Count the number of each grade, grouped by module
-- Note: the table alias "smp" is needed because the output columns
-- (mod_registered, grade) have the same names as the table's columns,
-- which would otherwise cause a "column reference is ambiguous" error.
CREATE OR REPLACE FUNCTION get_modules_performance()
RETURNS TABLE (
    mod_registered VARCHAR(10),
    grade CHAR(2),
    grade_count BIGINT
) AS
$$
BEGIN
    -- Use RETURN QUERY to define the query to be executed
    RETURN QUERY
    SELECT smp.mod_registered, smp.grade, COUNT(*) AS grade_count
    FROM stud_mod_performance smp
    GROUP BY smp.mod_registered, smp.grade
    ORDER BY smp.mod_registered, smp.grade;
END;
$$
LANGUAGE plpgsql;

-- Test (invoked with SELECT ... FROM, like a table) -> 28 rows
-- SELECT * FROM get_modules_performance();


-- Q2a: Return type of get_modules_performance
-- Answer: it returns a SET OF ROWS.
-- Evidence:
--   1. It is declared with RETURNS TABLE (mod_registered, grade, grade_count),
--      i.e. multiple rows with 3 columns, not a single scalar type
--      (compare get_grade_point, which is declared RETURNS NUMERIC).
--   2. The body uses RETURN QUERY, which returns every row produced by the SELECT.
--   3. It is invoked in the FROM clause like a table:
--      SELECT * FROM get_modules_performance()
--      whereas a single-value function is invoked as SELECT get_grade_point('A').
--   4. Executing it returns 28 rows x 3 columns.


-- Q2b: Rewrite using the alternative row-returning mechanism
-- OUT parameters define the columns; RETURNS SETOF RECORD returns many rows.
-- Given a new name (_v2) because CREATE OR REPLACE cannot change the
-- return type of the existing function.
CREATE OR REPLACE FUNCTION get_modules_performance_v2(
    OUT mod_registered VARCHAR(10),
    OUT grade CHAR(2),
    OUT grade_count BIGINT
)
RETURNS SETOF RECORD
AS $$
BEGIN
    RETURN QUERY
    SELECT smp.mod_registered, smp.grade, COUNT(*)
    FROM stud_mod_performance smp
    GROUP BY smp.mod_registered, smp.grade
    ORDER BY smp.mod_registered, smp.grade;
END;
$$ LANGUAGE plpgsql;

-- Test -> same 28 rows as get_modules_performance()
-- SELECT * FROM get_modules_performance_v2();


-- =====================================================================
-- Section C: Combining Function & Stored Procedure (Student GPA)
-- =====================================================================

-- Alter the student table to store each student's gpa
ALTER TABLE student
ADD COLUMN gpa NUMERIC(4, 2),
ADD COLUMN gpa_last_updated DATE;


-- Function to map a grade to its grade point (returns a single value)
CREATE OR REPLACE FUNCTION get_grade_point(grade_input CHAR(2))
RETURNS NUMERIC
AS $$
DECLARE
    grade_point NUMERIC;
BEGIN
    -- Base on output
    grade_point := CASE
        WHEN grade_input = 'AD' THEN 4.0
        WHEN grade_input = 'A'  THEN 4.0
        WHEN grade_input = 'B+' THEN 3.5
        WHEN grade_input = 'B'  THEN 3.0
        WHEN grade_input = 'C+' THEN 2.5
        WHEN grade_input = 'C'  THEN 2.0
        WHEN grade_input = 'D+' THEN 1.5
        WHEN grade_input = 'D'  THEN 1.0
        WHEN grade_input = 'F'  THEN 0.0
        ELSE NULL -- Assign NULL for invalid grades
    END;

    IF grade_point IS NULL THEN
        RAISE EXCEPTION 'Invalid Grade: %', grade_input;
    END IF;

    RETURN grade_point;
END;
$$ LANGUAGE plpgsql;

-- Test -> 3.5
-- SELECT get_grade_point('B+');


-- Stored Procedure to calculate and update GPAs for all students
-- gpa = (Total of (Grade Points * Module Credit Unit)) / (Total of Credit Units)
CREATE OR REPLACE PROCEDURE calculate_students_gpa()
AS $$
DECLARE
    -- Declare variables for procedure
    v_adm_no CHAR(4);
    v_mod_performance RECORD;
    total_credit_units INT;               -- total credit unit for each student in nested loop
    total_weighted_grade_points NUMERIC;  -- total grade points for each student in nested loop
    computed_gpa NUMERIC;                 -- gpa for each student
BEGIN
    -- Loop through the distinct students in stud_mod_performance
    FOR v_adm_no IN (
        SELECT DISTINCT adm_no FROM stud_mod_performance
    )
    LOOP
        -- Initialize total credit units and weighted grade points
        total_credit_units := 0;
        total_weighted_grade_points := 0;

        -- Nested loop that iterates over module performance records for a specific student
        -- JOIN with module to get the credit unit for each module taken
        FOR v_mod_performance IN
            SELECT smp.grade, m.credit_unit
            FROM stud_mod_performance smp
            JOIN module m ON smp.mod_registered = m.mod_code
            WHERE smp.adm_no = v_adm_no
        LOOP
            -- Accumulate credit units and (grade point * credit unit)
            total_credit_units := total_credit_units + v_mod_performance.credit_unit;
            total_weighted_grade_points := total_weighted_grade_points
                + get_grade_point(v_mod_performance.grade) * v_mod_performance.credit_unit;
        END LOOP;

        -- Calculate GPA if total credit units are greater than 0
        IF total_credit_units > 0 THEN
            computed_gpa := total_weighted_grade_points / total_credit_units;

            -- Update the student table with the computed gpa
            -- use today's date for gpa_last_updated
            UPDATE student
            SET gpa = computed_gpa,
                gpa_last_updated = CURRENT_DATE
            WHERE adm_no = v_adm_no;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Test (invoked with CALL), then check the results
-- CALL calculate_students_gpa();
-- SELECT adm_no, stud_name, gpa, gpa_last_updated FROM student;
