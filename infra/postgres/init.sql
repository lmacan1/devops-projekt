CREATE TABLE IF NOT EXISTS ticket_orders (
    order_id       UUID PRIMARY KEY,
    event_id       VARCHAR(50)  NOT NULL,
    customer_email VARCHAR(255) NOT NULL,
    quantity       INTEGER      NOT NULL,
    status         VARCHAR(50)  NOT NULL DEFAULT 'queued',
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
