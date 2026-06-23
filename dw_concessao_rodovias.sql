-- =============================================================================
--  DATA WAREHOUSE — CONCESSÃO DE RODOVIAS
--  Banco: MySQL 8.0+
--  Modelo: Fact Constellation (esquema em constelação)
--  Autor: gerado por Claude (Anthropic)
-- =============================================================================

CREATE DATABASE IF NOT EXISTS dw_rodovias
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE dw_rodovias;


-- =============================================================================
--  DIMENSÕES
-- =============================================================================

-- -----------------------------------------------------------------------------
--  DIM_TEMPO
--  Granularidade: dia. Calendário gerado via script ETL (2020-01-01 → 2030-12-31)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_tempo (
    id_tempo        INT             NOT NULL AUTO_INCREMENT,
    data            DATE            NOT NULL,
    dia             TINYINT         NOT NULL COMMENT 'Dia do mês (1-31)',
    dia_semana      VARCHAR(15)     NOT NULL COMMENT 'Segunda, Terça, ..., Domingo',
    num_dia_semana  TINYINT         NOT NULL COMMENT '1=Segunda … 7=Domingo',
    semana_ano      TINYINT         NOT NULL COMMENT 'Semana ISO (1-53)',
    mes             TINYINT         NOT NULL COMMENT 'Número do mês (1-12)',
    nome_mes        VARCHAR(15)     NOT NULL,
    trimestre       TINYINT         NOT NULL COMMENT '1 a 4',
    semestre        TINYINT         NOT NULL COMMENT '1 ou 2',
    ano             SMALLINT        NOT NULL,
    estacao_ano     VARCHAR(10)     NOT NULL COMMENT 'Verão, Outono, Inverno, Primavera',
    feriado_nacional BOOLEAN        NOT NULL DEFAULT FALSE,
    feriado_estadual BOOLEAN        NOT NULL DEFAULT FALSE,
    fim_de_semana   BOOLEAN         NOT NULL DEFAULT FALSE,
    vespera_feriado BOOLEAN         NOT NULL DEFAULT FALSE,
    periodo_ferias  BOOLEAN         NOT NULL DEFAULT FALSE
                        COMMENT 'Férias escolares (jan, jul, dez)',
    PRIMARY KEY (id_tempo),
    UNIQUE KEY uq_dim_tempo_data (data),
    KEY idx_dim_tempo_ano_mes (ano, mes),
    KEY idx_dim_tempo_ano (ano)
) ENGINE=InnoDB COMMENT='Dimensão de tempo com granularidade diária';


-- -----------------------------------------------------------------------------
--  DIM_TRECHO
--  Representa segmentos físicos monitorados ao longo da rodovia.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_trecho (
    id_trecho       INT             NOT NULL AUTO_INCREMENT,
    codigo          VARCHAR(20)     NOT NULL COMMENT 'Código interno do trecho (ex: SP-330-KM-100-120)',
    rodovia         VARCHAR(20)     NOT NULL COMMENT 'Ex: SP-330, BR-116',
    uf              CHAR(2)         NOT NULL,
    municipio_ini   VARCHAR(80)     NOT NULL,
    municipio_fim   VARCHAR(80)     NOT NULL,
    km_inicial      DECIMAL(7,3)    NOT NULL,
    km_final        DECIMAL(7,3)    NOT NULL,
    extensao_km     DECIMAL(7,3)    NOT NULL
                        COMMENT 'km_final - km_inicial (calculado na carga)',
    sentido         ENUM('Norte','Sul','Leste','Oeste','Ambos') NOT NULL DEFAULT 'Ambos',
    num_faixas      TINYINT         NOT NULL DEFAULT 2,
    tipo_piso       ENUM('CBUQ','TSS','Concreto','Paralelepípedo') NOT NULL DEFAULT 'CBUQ',
    ano_construcao  SMALLINT,
    PRIMARY KEY (id_trecho),
    UNIQUE KEY uq_dim_trecho_codigo (codigo),
    KEY idx_dim_trecho_rodovia (rodovia)
) ENGINE=InnoDB COMMENT='Segmentos físicos da rodovia concessionada';


-- -----------------------------------------------------------------------------
--  DIM_PRACA_PEDAGIO
--  Praças de pedágio associadas a um trecho.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_praca_pedagio (
    id_praca        INT             NOT NULL AUTO_INCREMENT,
    id_trecho       INT             NOT NULL,
    codigo_praca    VARCHAR(20)     NOT NULL,
    nome            VARCHAR(100)    NOT NULL,
    km_localizacao  DECIMAL(7,3)    NOT NULL,
    uf              CHAR(2)         NOT NULL,
    municipio       VARCHAR(80)     NOT NULL,
    tipo_sistema    ENUM('Manual','Automático','Free-Flow','Híbrido') NOT NULL,
    num_cabines     TINYINT         NOT NULL DEFAULT 4,
    ativa           BOOLEAN         NOT NULL DEFAULT TRUE,
    PRIMARY KEY (id_praca),
    UNIQUE KEY uq_dim_praca_codigo (codigo_praca),
    KEY idx_dim_praca_trecho (id_trecho),
    CONSTRAINT fk_praca_trecho
        FOREIGN KEY (id_trecho) REFERENCES dim_trecho (id_trecho)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB COMMENT='Praças de pedágio ao longo dos trechos';


-- -----------------------------------------------------------------------------
--  DIM_CATEGORIA_VEICULO
--  Categorias tarifárias conforme resolução ANTT/ARTESP.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_categoria_veiculo (
    id_categoria    INT             NOT NULL AUTO_INCREMENT,
    codigo          TINYINT         NOT NULL COMMENT 'Código oficial (1-8)',
    descricao       VARCHAR(80)     NOT NULL COMMENT 'Ex: Automóvel e moto, Caminhão 2 eixos',
    num_eixos       TINYINT         NOT NULL,
    tipo            ENUM('Leve','Comercial Leve','Pesado','Especial') NOT NULL,
    coef_multiplicador DECIMAL(4,2) NOT NULL DEFAULT 1.00
                        COMMENT 'Fator em relação à tarifa básica (cat 1 = 1,00)',
    PRIMARY KEY (id_categoria),
    UNIQUE KEY uq_dim_cat_codigo (codigo)
) ENGINE=InnoDB COMMENT='Categorias de veículos para cobrança de pedágio';


-- -----------------------------------------------------------------------------
--  DIM_TIPO_OCORRENCIA
--  Classificação de ocorrências e acidentes.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_tipo_ocorrencia (
    id_tipo_ocorrencia  INT         NOT NULL AUTO_INCREMENT,
    codigo              VARCHAR(10) NOT NULL,
    descricao           VARCHAR(100) NOT NULL COMMENT 'Ex: Colisão frontal, Atropelamento',
    categoria           ENUM('Acidente','Incidente','Emergência','Obstáculo') NOT NULL,
    gravidade           ENUM('Sem vítimas','Com feridos','Com óbitos','Danos materiais') NOT NULL,
    requer_pericia      BOOLEAN     NOT NULL DEFAULT FALSE,
    PRIMARY KEY (id_tipo_ocorrencia),
    UNIQUE KEY uq_dim_ocorrencia_codigo (codigo)
) ENGINE=InnoDB COMMENT='Tipos e categorias de ocorrências na rodovia';


-- -----------------------------------------------------------------------------
--  DIM_TIPO_MANUTENCAO
--  Tipos de intervenção de manutenção viária.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_tipo_manutencao (
    id_tipo_manutencao  INT         NOT NULL AUTO_INCREMENT,
    codigo              VARCHAR(10) NOT NULL,
    descricao           VARCHAR(100) NOT NULL COMMENT 'Ex: Recape, Remendo, Roçagem',
    grupo               ENUM('Pavimento','Drenagem','Sinalização','Estruturas','Vegetação','Elétrica') NOT NULL,
    criticidade         ENUM('Preventiva','Corretiva','Emergencial') NOT NULL,
    impacto_trafego     ENUM('Sem impacto','Bloqueio parcial','Bloqueio total') NOT NULL DEFAULT 'Sem impacto',
    PRIMARY KEY (id_tipo_manutencao),
    UNIQUE KEY uq_dim_manutencao_codigo (codigo)
) ENGINE=InnoDB COMMENT='Tipos de intervenção de manutenção viária';


-- =============================================================================
--  TABELAS FATO
-- =============================================================================

-- -----------------------------------------------------------------------------
--  FACT_TRAFEGO
--  Granularidade: um registro por dia × trecho × categoria de veículo.
--  Indica volume de tráfego e velocidade média por período.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_trafego (
    id_trafego          BIGINT          NOT NULL AUTO_INCREMENT,
    id_tempo            INT             NOT NULL,
    id_trecho           INT             NOT NULL,
    id_categoria        INT             NOT NULL,
    volume_veiculos     INT             NOT NULL DEFAULT 0
                            COMMENT 'Total de veículos no período',
    velocidade_media    DECIMAL(5,1)    COMMENT 'km/h — NULL se sensor inativo',
    velocidade_minima   DECIMAL(5,1)    COMMENT 'km/h',
    velocidade_maxima   DECIMAL(5,1)    COMMENT 'km/h',
    tempo_viagem_min    DECIMAL(6,1)    COMMENT 'Minutos médios no trecho',
    indice_congestion   DECIMAL(4,3)    COMMENT '0.0 (livre) a 1.0 (parado)',
    PRIMARY KEY (id_trafego),
    UNIQUE KEY uq_fact_traf (id_tempo, id_trecho, id_categoria),
    KEY idx_fact_traf_tempo    (id_tempo),
    KEY idx_fact_traf_trecho   (id_trecho),
    KEY idx_fact_traf_cat      (id_categoria),
    CONSTRAINT fk_traf_tempo
        FOREIGN KEY (id_tempo)     REFERENCES dim_tempo (id_tempo)    ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_traf_trecho
        FOREIGN KEY (id_trecho)    REFERENCES dim_trecho (id_trecho)  ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_traf_cat
        FOREIGN KEY (id_categoria) REFERENCES dim_categoria_veiculo (id_categoria) ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB COMMENT='Fato: volume de tráfego diário por trecho e categoria';


-- -----------------------------------------------------------------------------
--  FACT_ACIDENTES
--  Granularidade: um registro por ocorrência/acidente registrado.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_acidentes (
    id_acidente             BIGINT      NOT NULL AUTO_INCREMENT,
    id_tempo                INT         NOT NULL,
    id_trecho               INT         NOT NULL,
    id_tipo_ocorrencia      INT         NOT NULL,
    hora_ocorrencia         TIME        COMMENT 'Hora aproximada do evento',
    qtd_veiculos_envolvidos TINYINT     NOT NULL DEFAULT 1,
    qtd_obitos              TINYINT     NOT NULL DEFAULT 0,
    qtd_feridos_graves      TINYINT     NOT NULL DEFAULT 0,
    qtd_feridos_leves       TINYINT     NOT NULL DEFAULT 0,
    tempo_atendimento_min   SMALLINT    COMMENT 'Minutos até chegada da equipe de socorro',
    tempo_liberacao_min     SMALLINT    COMMENT 'Minutos até liberação da via',
    pista_molhada           BOOLEAN     NOT NULL DEFAULT FALSE,
    condicao_tempo          ENUM('Claro','Nublado','Chuva','Neblina','Granizo') DEFAULT 'Claro',
    periodo_dia             ENUM('Madrugada','Manhã','Tarde','Noite') NOT NULL,
    PRIMARY KEY (id_acidente),
    KEY idx_fact_acid_tempo    (id_tempo),
    KEY idx_fact_acid_trecho   (id_trecho),
    KEY idx_fact_acid_tipo     (id_tipo_ocorrencia),
    CONSTRAINT fk_acid_tempo
        FOREIGN KEY (id_tempo)           REFERENCES dim_tempo (id_tempo)              ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_acid_trecho
        FOREIGN KEY (id_trecho)          REFERENCES dim_trecho (id_trecho)            ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_acid_tipo
        FOREIGN KEY (id_tipo_ocorrencia) REFERENCES dim_tipo_ocorrencia (id_tipo_ocorrencia) ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB COMMENT='Fato: ocorrências e acidentes registrados na rodovia';


-- -----------------------------------------------------------------------------
--  FACT_ARRECADACAO
--  Granularidade: um registro por dia × praça × categoria de veículo.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_arrecadacao (
    id_arrecadacao      BIGINT          NOT NULL AUTO_INCREMENT,
    id_tempo            INT             NOT NULL,
    id_praca            INT             NOT NULL,
    id_categoria        INT             NOT NULL,
    qtd_transacoes      INT             NOT NULL DEFAULT 0,
    qtd_isencoes        INT             NOT NULL DEFAULT 0
                            COMMENT 'Isenções (deficientes, emergência, etc.)',
    receita_bruta       DECIMAL(12,2)   NOT NULL DEFAULT 0.00 COMMENT 'R$',
    receita_tag         DECIMAL(12,2)   NOT NULL DEFAULT 0.00 COMMENT 'R$ — pagamentos via AVI/tag',
    receita_manual      DECIMAL(12,2)   NOT NULL DEFAULT 0.00 COMMENT 'R$ — pagamentos em dinheiro',
    evasao_estimada     DECIMAL(12,2)   NOT NULL DEFAULT 0.00
                            COMMENT 'R$ — estimativa de evasão por free-flow',
    tarifa_vigente      DECIMAL(7,2)    NOT NULL COMMENT 'R$ — tarifa da categoria no dia',
    PRIMARY KEY (id_arrecadacao),
    UNIQUE KEY uq_fact_arrec (id_tempo, id_praca, id_categoria),
    KEY idx_fact_arrec_tempo  (id_tempo),
    KEY idx_fact_arrec_praca  (id_praca),
    KEY idx_fact_arrec_cat    (id_categoria),
    CONSTRAINT fk_arrec_tempo
        FOREIGN KEY (id_tempo)     REFERENCES dim_tempo (id_tempo)              ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_arrec_praca
        FOREIGN KEY (id_praca)     REFERENCES dim_praca_pedagio (id_praca)      ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_arrec_cat
        FOREIGN KEY (id_categoria) REFERENCES dim_categoria_veiculo (id_categoria) ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB COMMENT='Fato: arrecadação diária por praça de pedágio e categoria';


-- -----------------------------------------------------------------------------
--  FACT_MANUTENCAO
--  Granularidade: um registro por ordem de serviço de manutenção.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_manutencao (
    id_manutencao           BIGINT          NOT NULL AUTO_INCREMENT,
    id_tempo                INT             NOT NULL COMMENT 'Data de início da intervenção',
    id_trecho               INT             NOT NULL,
    id_tipo_manutencao      INT             NOT NULL,
    data_conclusao          DATE            COMMENT 'NULL = em andamento',
    dias_intervencao        SMALLINT        COMMENT 'Duração total em dias corridos',
    extensao_tratada_km     DECIMAL(7,3)    COMMENT 'Extensão de via tratada (km)',
    custo_material          DECIMAL(12,2)   NOT NULL DEFAULT 0.00 COMMENT 'R$',
    custo_mao_obra          DECIMAL(12,2)   NOT NULL DEFAULT 0.00 COMMENT 'R$',
    custo_equipamento       DECIMAL(12,2)   NOT NULL DEFAULT 0.00 COMMENT 'R$',
    custo_total             DECIMAL(12,2)   NOT NULL DEFAULT 0.00
                                COMMENT 'R$ — soma dos três custos',
    igp_antes               DECIMAL(5,2)    COMMENT 'Índice de Gravidade Global antes',
    igp_depois              DECIMAL(5,2)    COMMENT 'Índice de Gravidade Global depois',
    chuvas_ultimos_30d_mm   DECIMAL(7,1)    COMMENT 'Precipitação acumulada antes da intervenção',
    origem                  ENUM('Programada','Corretiva','Emergencial') NOT NULL DEFAULT 'Programada',
    PRIMARY KEY (id_manutencao),
    KEY idx_fact_man_tempo   (id_tempo),
    KEY idx_fact_man_trecho  (id_trecho),
    KEY idx_fact_man_tipo    (id_tipo_manutencao),
    CONSTRAINT fk_man_tempo
        FOREIGN KEY (id_tempo)           REFERENCES dim_tempo (id_tempo)               ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_man_trecho
        FOREIGN KEY (id_trecho)          REFERENCES dim_trecho (id_trecho)             ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_man_tipo
        FOREIGN KEY (id_tipo_manutencao) REFERENCES dim_tipo_manutencao (id_tipo_manutencao) ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB COMMENT='Fato: ordens de serviço de manutenção viária';


-- =============================================================================
--  DADOS DE REFERÊNCIA — LOOKUP TABLES
--  Populadas na instalação; raramente alteradas.
-- =============================================================================

INSERT IGNORE INTO dim_categoria_veiculo
    (codigo, descricao, num_eixos, tipo, coef_multiplicador)
VALUES
    (1, 'Automóvel, caminhonete e furgão',        2, 'Leve',           1.00),
    (2, 'Caminhão leve, ônibus, caminhonete',      2, 'Comercial Leve', 1.50),
    (3, 'Automóvel com semirreboque',              3, 'Comercial Leve', 2.00),
    (4, 'Caminhão (3 eixos)',                      3, 'Pesado',         2.00),
    (5, 'Caminhão (4 eixos)',                      4, 'Pesado',         3.00),
    (6, 'Caminhão-trator / trans. especial 5 ei', 5, 'Pesado',         3.00),
    (7, 'Caminhão-trator / trans. especial 6 ei', 6, 'Pesado',         4.00),
    (8, 'Caminhão-trator / trans. especial 7+ ei',7, 'Especial',       4.00);


INSERT IGNORE INTO dim_tipo_ocorrencia
    (codigo, descricao, categoria, gravidade, requer_pericia)
VALUES
    ('AC-CF', 'Colisão frontal',                'Acidente',   'Com óbitos',       TRUE),
    ('AC-CT', 'Colisão traseira',               'Acidente',   'Com feridos',      FALSE),
    ('AC-CL', 'Colisão lateral',                'Acidente',   'Com feridos',      FALSE),
    ('AC-SA', 'Saída de pista',                 'Acidente',   'Sem vítimas',      FALSE),
    ('AC-CA', 'Capotamento',                    'Acidente',   'Com feridos',      TRUE),
    ('AC-AT', 'Atropelamento de pedestre',      'Acidente',   'Com óbitos',       TRUE),
    ('AC-AF', 'Atropelamento de fauna',         'Acidente',   'Sem vítimas',      FALSE),
    ('IN-VE', 'Veículo avariado na pista',      'Incidente',  'Danos materiais',  FALSE),
    ('IN-CA', 'Carga caída',                    'Incidente',  'Danos materiais',  FALSE),
    ('EM-IN', 'Incêndio em veículo',            'Emergência', 'Com feridos',      TRUE),
    ('OB-OB', 'Objeto na pista',                'Obstáculo',  'Sem vítimas',      FALSE);


INSERT IGNORE INTO dim_tipo_manutencao
    (codigo, descricao, grupo, criticidade, impacto_trafego)
VALUES
    ('PAV-RC', 'Recape asfáltico',               'Pavimento',    'Preventiva',   'Bloqueio parcial'),
    ('PAV-RM', 'Remendo a frio',                 'Pavimento',    'Corretiva',    'Sem impacto'),
    ('PAV-RP', 'Remendo profundo',               'Pavimento',    'Corretiva',    'Bloqueio parcial'),
    ('PAV-FR', 'Fresagem e revestimento',        'Pavimento',    'Preventiva',   'Bloqueio total'),
    ('PAV-TR', 'Tratamento superficial',         'Pavimento',    'Preventiva',   'Sem impacto'),
    ('DRE-LI', 'Limpeza de bueiros',             'Drenagem',     'Preventiva',   'Sem impacto'),
    ('DRE-RE', 'Recuperação de sarjeta',         'Drenagem',     'Corretiva',    'Sem impacto'),
    ('SIN-HO', 'Pintura de sinalização horizon', 'Sinalização',  'Preventiva',   'Sem impacto'),
    ('SIN-VE', 'Instalação / troca de placa',   'Sinalização',  'Corretiva',    'Sem impacto'),
    ('SIN-GU', 'Guarda-corpo e defensas',        'Sinalização',  'Corretiva',    'Bloqueio parcial'),
    ('EST-PO', 'Recuperação de ponte/viaduto',  'Estruturas',   'Corretiva',    'Bloqueio total'),
    ('VEG-RO', 'Roçagem de vegetação',           'Vegetação',    'Preventiva',   'Sem impacto'),
    ('ELE-IL', 'Manutenção de iluminação',       'Elétrica',     'Corretiva',    'Sem impacto'),
    ('MAN-EM', 'Intervenção emergencial',        'Pavimento',    'Emergencial',  'Bloqueio total');


-- =============================================================================
--  VIEWS ANALÍTICAS
-- =============================================================================

CREATE OR REPLACE VIEW vw_trafego_mensal AS
SELECT
    t.ano,
    t.mes,
    t.nome_mes,
    tr.rodovia,
    tr.codigo         AS trecho,
    c.descricao       AS categoria,
    SUM(f.volume_veiculos)               AS total_veiculos,
    AVG(f.velocidade_media)              AS vel_media_kmh,
    AVG(f.indice_congestion)             AS congestion_medio
FROM fact_trafego f
JOIN dim_tempo    t  ON f.id_tempo    = t.id_tempo
JOIN dim_trecho   tr ON f.id_trecho   = tr.id_trecho
JOIN dim_categoria_veiculo c ON f.id_categoria = c.id_categoria
GROUP BY t.ano, t.mes, t.nome_mes, tr.rodovia, tr.codigo, c.descricao;


CREATE OR REPLACE VIEW vw_acidentes_mensal AS
SELECT
    t.ano,
    t.mes,
    t.nome_mes,
    tr.rodovia,
    tr.codigo         AS trecho,
    o.categoria       AS tipo_ocorrencia,
    o.gravidade,
    COUNT(*)                             AS total_ocorrencias,
    SUM(f.qtd_obitos)                    AS total_obitos,
    SUM(f.qtd_feridos_graves + f.qtd_feridos_leves) AS total_feridos,
    AVG(f.tempo_atendimento_min)         AS tempo_medio_atend_min
FROM fact_acidentes f
JOIN dim_tempo          t  ON f.id_tempo           = t.id_tempo
JOIN dim_trecho         tr ON f.id_trecho           = tr.id_trecho
JOIN dim_tipo_ocorrencia o ON f.id_tipo_ocorrencia  = o.id_tipo_ocorrencia
GROUP BY t.ano, t.mes, t.nome_mes, tr.rodovia, tr.codigo, o.categoria, o.gravidade;


CREATE OR REPLACE VIEW vw_arrecadacao_mensal AS
SELECT
    t.ano,
    t.mes,
    t.nome_mes,
    p.nome            AS praca,
    tr.rodovia,
    c.descricao       AS categoria,
    SUM(f.qtd_transacoes)                AS total_transacoes,
    SUM(f.receita_bruta)                 AS receita_bruta_r$,
    SUM(f.receita_tag)                   AS receita_tag_r$,
    SUM(f.receita_manual)                AS receita_manual_r$,
    SUM(f.evasao_estimada)               AS evasao_r$
FROM fact_arrecadacao f
JOIN dim_tempo           t  ON f.id_tempo    = t.id_tempo
JOIN dim_praca_pedagio   p  ON f.id_praca    = p.id_praca
JOIN dim_trecho          tr ON p.id_trecho   = tr.id_trecho
JOIN dim_categoria_veiculo c ON f.id_categoria = c.id_categoria
GROUP BY t.ano, t.mes, t.nome_mes, p.nome, tr.rodovia, c.descricao;


CREATE OR REPLACE VIEW vw_manutencao_mensal AS
SELECT
    t.ano,
    t.mes,
    t.nome_mes,
    tr.rodovia,
    tr.codigo         AS trecho,
    m.grupo,
    m.criticidade,
    COUNT(*)                             AS total_ordens,
    SUM(f.extensao_tratada_km)           AS extensao_total_km,
    SUM(f.custo_total)                   AS custo_total_r$,
    AVG(f.dias_intervencao)              AS duracao_media_dias
FROM fact_manutencao f
JOIN dim_tempo           t  ON f.id_tempo           = t.id_tempo
JOIN dim_trecho          tr ON f.id_trecho           = tr.id_trecho
JOIN dim_tipo_manutencao m  ON f.id_tipo_manutencao  = m.id_tipo_manutencao
GROUP BY t.ano, t.mes, t.nome_mes, tr.rodovia, tr.codigo, m.grupo, m.criticidade;

-- FIM DO SCRIPT DDL
