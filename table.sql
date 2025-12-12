--таблица peers
CREATE TABLE IF NOT EXISTS peers (
    nickname VARCHAR(50) PRIMARY KEY,
    birthday DATE NOT NULL
);

-- таблица tasks
CREATE TABLE IF NOT EXISTS tasks (
    title VARCHAR(100) PRIMARY KEY,
    parenttask VARCHAR(100),
    maxxp INTEGER NOT NULL CHECK (maxxp > 0),
    FOREIGN KEY (parenttask) REFERENCES tasks(title)
);

-- таблица checks
CREATE TABLE IF NOT EXISTS checks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    peer VARCHAR(50) NOT NULL,
    task VARCHAR(100) NOT NULL,
    date DATE NOT NULL DEFAULT (DATE('now')),
    FOREIGN KEY (peer) REFERENCES peers(nickname),
    FOREIGN KEY (task) REFERENCES tasks(title)
);

-- таблица p2p
CREATE TABLE IF NOT EXISTS p2p (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    check_id INTEGER NOT NULL,
    checkingpeer VARCHAR(50) NOT NULL,
    state VARCHAR(10) NOT NULL CHECK (state IN ('Start', 'Success', 'Failure')),
    time TIME NOT NULL DEFAULT (TIME('now')),
    FOREIGN KEY (check_id) REFERENCES checks(id),
    FOREIGN KEY (checkingpeer) REFERENCES peers(nickname)
);

-- таблица verter
CREATE TABLE IF NOT EXISTS verter (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    check_id INTEGER NOT NULL,
    state VARCHAR(10) NOT NULL CHECK (state IN ('Start', 'Success', 'Failure')),
    time TIME NOT NULL DEFAULT (TIME('now')),
    FOREIGN KEY (check_id) REFERENCES checks(id)
);

-- таблица transferredpoints
CREATE TABLE IF NOT EXISTS transferredpoints (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    checkingpeer VARCHAR(50) NOT NULL,
    checkedpeer VARCHAR(50) NOT NULL,
    pointsamount INTEGER NOT NULL DEFAULT 1,
    CHECK (checkingpeer != checkedpeer),
    FOREIGN KEY (checkingpeer) REFERENCES peers(nickname),
    FOREIGN KEY (checkedpeer) REFERENCES peers(nickname)
);

-- таблица friends
CREATE TABLE IF NOT EXISTS friends (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    peer1 VARCHAR(50) NOT NULL,
    peer2 VARCHAR(50) NOT NULL,
    CHECK (peer1 != peer2),
    FOREIGN KEY (peer1) REFERENCES peers(nickname),
    FOREIGN KEY (peer2) REFERENCES peers(nickname)
);

-- таблица recommendations
CREATE TABLE IF NOT EXISTS recommendations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    peer VARCHAR(50) NOT NULL,
    recommendedpeer VARCHAR(50) NOT NULL,
    CHECK (peer != recommendedpeer),
    FOREIGN KEY (peer) REFERENCES peers(nickname),
    FOREIGN KEY (recommendedpeer) REFERENCES peers(nickname)
);

-- таблица xp
CREATE TABLE IF NOT EXISTS xp (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    check_id INTEGER NOT NULL,
    xpamount INTEGER NOT NULL CHECK (xpamount > 0),
    FOREIGN KEY (check_id) REFERENCES checks(id)
);

-- таблица timetracking
CREATE TABLE IF NOT EXISTS timetracking (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    peer VARCHAR(50) NOT NULL,
    date DATE NOT NULL DEFAULT (DATE('now')),
    time TIME NOT NULL DEFAULT (TIME('now')),
    state INTEGER NOT NULL CHECK (state IN (1, 2)),
    FOREIGN KEY (peer) REFERENCES peers(nickname)
);

-- Индексы для производительности
CREATE INDEX IF NOT EXISTS idx_checks_peer ON checks(peer);
CREATE INDEX IF NOT EXISTS idx_checks_task ON checks(task);
CREATE INDEX IF NOT EXISTS idx_p2p_check_id ON p2p(check_id);
CREATE INDEX IF NOT EXISTS idx_verter_check_id ON verter(check_id);
CREATE INDEX IF NOT EXISTS idx_xp_check_id ON xp(check_id);
CREATE INDEX IF NOT EXISTS idx_timetracking_peer_date ON timetracking(peer, date);
CREATE INDEX IF NOT EXISTS idx_transferredpoints_peers ON transferredpoints(checkingpeer, checkedpeer);

-- Процедура add_p2p_check, добавляет запись о P2P-проверке. При статусе "Start" создаёт новую проверку
CREATE OR REPLACE PROCEDURE add_verter_check(
    checked_peer VARCHAR,
    task_name VARCHAR,
    status check_status,
    check_time TIME
)
LANGUAGE plpgsql AS $$
DECLARE
    check_id BIGINT;
BEGIN
    SELECT MAX(id) INTO check_id FROM checks 
    WHERE peer = checked_peer AND task = task_name;
    
    INSERT INTO verter (check_id, state, time) 
    VALUES (check_id, status, check_time);
END;
$$;

-- Триггер update_transferredpoints, при старте P2P-проверки увеличивает счётчик переданных очков
CREATE OR REPLACE FUNCTION update_transferredpoints_func()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.state = 'Start' THEN
        INSERT INTO transferredpoints (checkingpeer, checkedpeer, pointsamount)
        VALUES (NEW.checkingpeer, 
                (SELECT peer FROM checks WHERE id = NEW.check_id), 
                1)
        ON CONFLICT (checkingpeer, checkedpeer) 
        DO UPDATE SET pointsamount = transferredpoints.pointsamount + 1;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_transferredpoints_trigger
AFTER INSERT ON p2p
FOR EACH ROW EXECUTE FUNCTION update_transferredpoints_func();

-- Триггер update_xp, проверяет чтобы XP не превышало максимальное
CREATE OR REPLACE FUNCTION update_xp_func()
RETURNS TRIGGER AS $$
DECLARE
    max_xp INTEGER;
    current_xp INTEGER;
BEGIN
    SELECT maxxp INTO max_xp FROM tasks 
    WHERE title = (SELECT task FROM checks WHERE id = NEW.check_id);
    
    IF NEW.xpamount > max_xp THEN
        RAISE EXCEPTION 'XP превышает максимальное для задачи';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_xp_trigger
BEFORE INSERT ON xp
FOR EACH ROW EXECUTE FUNCTION update_xp_func();

--Функция human_readable_transferredpoints, возвращает сводную таблицу переданных очков
CREATE OR REPLACE FUNCTION human_readable_transferredpoints()
RETURNS TABLE (Peer1 VARCHAR, Peer2 VARCHAR, Points INTEGER) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        tp.checkingpeer AS Peer1,
        tp.checkedpeer AS Peer2,
        SUM(tp.pointsamount) AS Points
    FROM transferredpoints tp
    GROUP BY tp.checkingpeer, tp.checkedpeer
    ORDER BY Peer1, Peer2;
END;
$$ LANGUAGE plpgsql;

--Функция get_peer_xp, возвращает задачи и XP указанного пира
CREATE OR REPLACE FUNCTION get_peer_xp(peer_name VARCHAR)
RETURNS TABLE (Task VARCHAR, XP INTEGER) AS $$
BEGIN
    RETURN QUERY
    SELECT t.title, x.xpamount
    FROM xp x
    JOIN checks c ON x.check_id = c.id
    JOIN tasks t ON c.task = t.title
    WHERE c.peer = peer_name;
END;
$$ LANGUAGE plpgsql;

--Функция peers_never_left_campus, возвращает пиров, которые за указанную дату только входили, но не выходили
CREATE OR REPLACE FUNCTION peers_never_left_campus(check_date DATE)
RETURNS TABLE (Peer VARCHAR) AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT t1.peer
    FROM timetracking t1
    WHERE t1.date = check_date
    AND NOT EXISTS (
        SELECT 1 FROM timetracking t2
        WHERE t2.peer = t1.peer
        AND t2.date = check_date
        AND t2.state = 2
    );
END;
$$ LANGUAGE plpgsql;

--Функция calculate_points_change, рассчитывает изменение очков каждого пира на основе transferredpoints
CREATE OR REPLACE FUNCTION calculate_points_change()
RETURNS TABLE (Peer VARCHAR, PointsChange INTEGER) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        p.nickname,
        COALESCE(SUM(
            CASE 
                WHEN tp.checkingpeer = p.nickname THEN tp.pointsamount
                WHEN tp.checkedpeer = p.nickname THEN -tp.pointsamount
                ELSE 0
            END
        ), 0) AS PointsChange
    FROM peers p
    LEFT JOIN transferredpoints tp ON p.nickname IN (tp.checkingpeer, tp.checkedpeer)
    GROUP BY p.nickname
    ORDER BY PointsChange DESC;
END;
$$ LANGUAGE plpgsql;

--Процедура drop_all_tables, удаляет все таблицы в текущей БД
CREATE OR REPLACE PROCEDURE drop_all_tables()
LANGUAGE plpgsql AS $$
DECLARE
    table_name TEXT;
BEGIN
    FOR table_name IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public')
    LOOP
        EXECUTE 'DROP TABLE IF EXISTS ' || table_name || ' CASCADE';
    END LOOP;
END;
$$;

--Процедура list_user_functions, выводит список пользовательских функций и их параметров
CREATE OR REPLACE PROCEDURE list_user_functions()
LANGUAGE plpgsql AS $$
DECLARE
    func_record RECORD;
BEGIN
    FOR func_record IN (
        SELECT 
            p.proname AS function_name,
            pg_get_function_arguments(p.oid) AS arguments
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public' 
        AND p.prokind = 'f'
    )
    LOOP
        RAISE NOTICE 'Function: %, Arguments: %', 
            func_record.function_name, 
            func_record.arguments;
    END LOOP;
END;
$$;

--Процедура drop_all_triggers, удаляет все триггеры в текущей БД
CREATE OR REPLACE PROCEDURE drop_all_triggers()
LANGUAGE plpgsql AS $$
DECLARE
    trigger_record RECORD;
BEGIN
    FOR trigger_record IN (
        SELECT tgname, tgrelid::regclass AS table_name
        FROM pg_trigger
        WHERE tgrelid IN (
            SELECT oid FROM pg_class 
            WHERE relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
        )
        AND tgisinternal = FALSE
    )
    LOOP
        EXECUTE 'DROP TRIGGER IF EXISTS ' || trigger_record.tgname || 
                ' ON ' || trigger_record.table_name;
    END LOOP;
END;
$$;

--Процедура search_objects_by_string, ищет объекты БД по строке в имени
CREATE OR REPLACE PROCEDURE search_objects_by_string(search_text TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    obj_record RECORD;
BEGIN
    FOR obj_record IN (
        SELECT 
            oid::regclass AS object_name,
            obj_description(oid) AS description
        FROM pg_class
        WHERE relkind IN ('r', 'v', 'm', 'f', 'p') 
        AND oid::regclass::TEXT ILIKE '%' || search_text || '%'
    )
    LOOP
        RAISE NOTICE 'Object: %, Description: %', 
            obj_record.object_name, 
            obj_record.description;
    END LOOP;
END;
$$;
