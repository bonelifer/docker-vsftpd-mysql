CREATE TABLE IF NOT EXISTS users (
    id       INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name     VARCHAR(64)  NOT NULL UNIQUE,
    password VARCHAR(128) NOT NULL
);

-- Test login: testuser / testpass (crypt(3) SHA-512 hash, matches MYSQL_PASSWD_CRYPT=1)
INSERT INTO users (name, password) VALUES
    ('testuser', '$6$.j0zPzZ/6dpBjnsw$BZI0nQnpH4SDyhQVaZ9TeQO7PghxKkCCvQVBVWbxzFYIpHI/qAKY/kuw81B/Yrp69AHTWuExVCu0UoY7kl.Na.');
