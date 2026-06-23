-- =============================================================================
--  POPULAÇÃO DO DW — CONCESSÃO DE RODOVIAS
--  Dados sintéticos com padrões sazonais reais  |  2022-01-01 a 2026-06-21
--  MySQL 8.0+  |  Execute APÓS dw_concessao_rodovias.sql
-- =============================================================================

USE dw_rodovias;

-- desabilita checagem de FK durante a carga (reabilita no final)
SET FOREIGN_KEY_CHECKS = 0;


-- =============================================================================
--  1. DIM_TEMPO  (~4,5 anos de histórico: 2022-01-01 a 2026-06-21)
--  Gerada via procedure para evitar 1 095 INSERTs manuais
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_pop_dim_tempo;

DELIMITER $$
CREATE PROCEDURE sp_pop_dim_tempo(IN p_ini DATE, IN p_fim DATE)
BEGIN
    DECLARE v_d   DATE    DEFAULT p_ini;
    DECLARE v_m   TINYINT;
    DECLARE v_dow TINYINT;

    WHILE v_d <= p_fim DO
        SET v_m   = MONTH(v_d);
        SET v_dow = DAYOFWEEK(v_d);   -- 1=Dom … 7=Sáb

        INSERT IGNORE INTO dim_tempo (
            data, dia, dia_semana, num_dia_semana, semana_ano,
            mes, nome_mes, trimestre, semestre, ano,
            estacao_ano, feriado_nacional, feriado_estadual,
            fim_de_semana, vespera_feriado, periodo_ferias
        ) VALUES (
            v_d,
            DAY(v_d),
            -- nome do dia em português
            ELT(v_dow, 'Domingo','Segunda','Terça','Quarta','Quinta','Sexta','Sábado'),
            -- num_dia_semana: 1=Seg … 7=Dom (padrão ISO)
            CASE v_dow WHEN 2 THEN 1 WHEN 3 THEN 2 WHEN 4 THEN 3
                       WHEN 5 THEN 4 WHEN 6 THEN 5 WHEN 7 THEN 6 ELSE 7 END,
            WEEK(v_d, 3),
            v_m,
            ELT(v_m,'Janeiro','Fevereiro','Março','Abril','Maio','Junho',
                     'Julho','Agosto','Setembro','Outubro','Novembro','Dezembro'),
            QUARTER(v_d),
            IF(v_m <= 6, 1, 2),
            YEAR(v_d),
            -- estação do ano (hemisfério sul)
            CASE WHEN v_m IN (12,1,2)  THEN 'Verão'
                 WHEN v_m IN (3,4,5)   THEN 'Outono'
                 WHEN v_m IN (6,7,8)   THEN 'Inverno'
                 ELSE 'Primavera' END,
            -- feriados nacionais fixos
            DATE_FORMAT(v_d,'%m-%d') IN (
                '01-01','04-21','05-01','09-07',
                '10-12','11-02','11-15','11-20','12-25'),
            FALSE,                          -- feriado_estadual (pode ser enriquecido)
            v_dow IN (1,7),                 -- fim_de_semana (dom/sáb)
            FALSE,                          -- vespera_feriado (simplificado)
            v_m IN (1,7,12)                 -- periodo_ferias (jan/jul/dez)
        );

        SET v_d = v_d + INTERVAL 1 DAY;
    END WHILE;
END$$
DELIMITER ;

CALL sp_pop_dim_tempo('2022-01-01', '2026-06-21');
DROP PROCEDURE IF EXISTS sp_pop_dim_tempo;


-- =============================================================================
--  2. DIM_TRECHO
--  5 segmentos da SP-330 (Rodovia Anhanguera) — São Paulo → Americana
-- =============================================================================
INSERT IGNORE INTO dim_trecho
    (codigo,             rodovia,  uf,  municipio_ini, municipio_fim, km_inicial, km_final, extensao_km, sentido,  num_faixas, tipo_piso, ano_construcao)
VALUES
    ('SP330-KM000-020', 'SP-330', 'SP', 'São Paulo',   'Guarulhos',     0.0,  20.0,  20.0, 'Ambos', 4, 'CBUQ', 1970),
    ('SP330-KM020-050', 'SP-330', 'SP', 'Guarulhos',   'Caieiras',     20.0,  50.0,  30.0, 'Ambos', 4, 'CBUQ', 1972),
    ('SP330-KM050-090', 'SP-330', 'SP', 'Caieiras',    'Jundiaí',      50.0,  90.0,  40.0, 'Ambos', 3, 'CBUQ', 1975),
    ('SP330-KM090-130', 'SP-330', 'SP', 'Jundiaí',     'Campinas',     90.0, 130.0,  40.0, 'Ambos', 3, 'CBUQ', 1975),
    ('SP330-KM130-170', 'SP-330', 'SP', 'Campinas',    'Americana',   130.0, 170.0,  40.0, 'Ambos', 2, 'CBUQ', 1978);


-- =============================================================================
--  3. DIM_PRACA_PEDAGIO
--  3 praças ao longo da SP-330
-- =============================================================================
INSERT IGNORE INTO dim_praca_pedagio
    (id_trecho, codigo_praca, nome,               km_localizacao, uf,   municipio,  tipo_sistema,  num_cabines, ativa)
VALUES
    (2, 'SP330-P01', 'Praça Caieiras',    38.5, 'SP', 'Caieiras',  'Híbrido',    6, TRUE),
    (3, 'SP330-P02', 'Praça Jundiaí',     78.0, 'SP', 'Jundiaí',   'Híbrido',    8, TRUE),
    (4, 'SP330-P03', 'Praça Campinas',   118.0, 'SP', 'Campinas',  'Free-Flow',  0, TRUE);


-- =============================================================================
--  4. FACT_TRAFEGO
--  ~65 300 linhas  |  1 633 dias × 5 trechos × 8 categorias
--
--  Padrões embutidos:
--    • Leves: pico em jan (verão+férias), jul (férias de inverno), dez
--             mais movimento na sexta/sábado, muito mais em feriados
--    • Pesados: pico de mai-set (safra), queda intensa no fim de semana/feriado
--    • Velocidade e congestionamento: inversamente proporcionais ao volume
-- =============================================================================
INSERT INTO fact_trafego
    (id_tempo, id_trecho, id_categoria,
     volume_veiculos, velocidade_media, velocidade_minima, velocidade_maxima,
     tempo_viagem_min, indice_congestion)
SELECT
    t.id_tempo,
    tr.id_trecho,
    c.id_categoria,

    /* ---- Volume de veículos ---- */
    GREATEST(1, ROUND(

        -- volume base diário por categoria (veículos/dia no trecho mais movimentado)
        CASE c.codigo
            WHEN 1 THEN 3200   -- automóveis e furgões
            WHEN 2 THEN  620   -- ônibus e caminhonetes comerciais
            WHEN 3 THEN  180   -- auto + semirreboque
            WHEN 4 THEN  750   -- caminhão 3 eixos
            WHEN 5 THEN  480   -- caminhão 4 eixos
            WHEN 6 THEN  320   -- bitrem 5 eixos
            WHEN 7 THEN  160   -- treminhão 6 eixos
            WHEN 8 THEN   60   -- especial 7+ eixos
        END

        -- fator de trecho (fluxo cai conforme avança para o interior)
        * CASE tr.codigo
            WHEN 'SP330-KM000-020' THEN 1.40
            WHEN 'SP330-KM020-050' THEN 1.15
            WHEN 'SP330-KM050-090' THEN 0.95
            WHEN 'SP330-KM090-130' THEN 0.90
            WHEN 'SP330-KM130-170' THEN 0.75
          END

        -- fator mensal — veículos leves
        * CASE
            WHEN c.codigo <= 3 THEN
                CASE t.mes
                    WHEN  1 THEN 1.45  -- verão + férias escolares
                    WHEN  2 THEN 1.25
                    WHEN  3 THEN 1.00
                    WHEN  4 THEN 0.88
                    WHEN  5 THEN 0.90
                    WHEN  6 THEN 0.95
                    WHEN  7 THEN 1.30  -- férias de julho
                    WHEN  8 THEN 1.00
                    WHEN  9 THEN 1.00
                    WHEN 10 THEN 1.05
                    WHEN 11 THEN 1.10
                    WHEN 12 THEN 1.35
                END
            -- fator mensal — veículos pesados (padrão safra agrícola SP)
            ELSE
                CASE t.mes
                    WHEN  1 THEN 0.80
                    WHEN  2 THEN 0.88
                    WHEN  3 THEN 1.02
                    WHEN  4 THEN 1.10
                    WHEN  5 THEN 1.15  -- início safra cana/laranja
                    WHEN  6 THEN 1.20
                    WHEN  7 THEN 0.95
                    WHEN  8 THEN 1.20
                    WHEN  9 THEN 1.25  -- pico safra
                    WHEN 10 THEN 1.20
                    WHEN 11 THEN 1.10
                    WHEN 12 THEN 0.85
                END
          END

        -- fator dia da semana
        * CASE
            WHEN c.codigo <= 3 THEN    -- leves: pico na sexta/sábado
                CASE t.num_dia_semana
                    WHEN 1 THEN 0.88   -- segunda
                    WHEN 2 THEN 0.85   -- terça
                    WHEN 3 THEN 0.87   -- quarta
                    WHEN 4 THEN 0.95   -- quinta
                    WHEN 5 THEN 1.20   -- sexta
                    WHEN 6 THEN 1.30   -- sábado
                    WHEN 7 THEN 1.10   -- domingo
                END
            ELSE                       -- pesados: queda drástica no fds
                CASE t.num_dia_semana
                    WHEN 1 THEN 1.20
                    WHEN 2 THEN 1.15
                    WHEN 3 THEN 1.10
                    WHEN 4 THEN 1.00
                    WHEN 5 THEN 0.85
                    WHEN 6 THEN 0.40
                    WHEN 7 THEN 0.20
                END
          END

        -- fator feriado
        * CASE
            WHEN t.feriado_nacional AND c.codigo <= 3 THEN 1.55
            WHEN t.feriado_nacional AND c.codigo  > 3 THEN 0.15
            ELSE 1.00
          END

        -- ruído aleatório ± 15%
        * (0.85 + RAND() * 0.30)

    )) AS volume_veiculos,

    /* ---- Velocidade média (km/h) ---- */
    ROUND(LEAST(120, GREATEST(20,
        CASE c.codigo
            WHEN 1 THEN 95.0  WHEN 2 THEN 90.0  WHEN 3 THEN 85.0
            WHEN 4 THEN 80.0  WHEN 5 THEN 75.0  WHEN 6 THEN 72.0
            WHEN 7 THEN 70.0  WHEN 8 THEN 68.0
        END
        * CASE WHEN t.feriado_nacional              THEN 0.70
               WHEN t.num_dia_semana IN (6,7)       THEN 0.85
               WHEN t.num_dia_semana = 5            THEN 0.90
               ELSE 1.00 END
        * CASE WHEN t.mes IN (12,1,2,3) THEN 0.93 ELSE 1.00 END  -- chuvas de verão
        * (0.90 + RAND() * 0.20)
    )), 1) AS velocidade_media,

    /* ---- Velocidade mínima ---- */
    ROUND(GREATEST(5,
        CASE c.codigo WHEN 1 THEN 60 WHEN 2 THEN 55 WHEN 3 THEN 50
                      WHEN 4 THEN 50 WHEN 5 THEN 45 WHEN 6 THEN 42
                      WHEN 7 THEN 40 ELSE 38 END
        * CASE WHEN t.feriado_nacional THEN 0.50 ELSE 0.80 END
        * (0.85 + RAND() * 0.15)
    ), 1) AS velocidade_minima,

    /* ---- Velocidade máxima ---- */
    ROUND(LEAST(140,
        CASE c.codigo WHEN 1 THEN 120 WHEN 2 THEN 110 WHEN 3 THEN 100
                      WHEN 4 THEN 100 WHEN 5 THEN  95 WHEN 6 THEN  90
                      WHEN 7 THEN  85 ELSE  80 END
        * (0.95 + RAND() * 0.10)
    ), 1) AS velocidade_maxima,

    /* ---- Tempo de viagem no trecho (min) ---- */
    ROUND(
        (tr.extensao_km / GREATEST(20,
            CASE c.codigo WHEN 1 THEN 95 WHEN 2 THEN 90 WHEN 3 THEN 85
                          WHEN 4 THEN 80 WHEN 5 THEN 75 WHEN 6 THEN 72
                          WHEN 7 THEN 70 ELSE 68 END
            * CASE WHEN t.feriado_nacional        THEN 0.70
                   WHEN t.num_dia_semana IN (6,7) THEN 0.85
                   ELSE 1.00 END
            * (0.90 + RAND() * 0.20)
        )) * 60
    , 1) AS tempo_viagem_min,

    /* ---- Índice de congestionamento (0=livre … 1=parado) ---- */
    ROUND(LEAST(0.98, GREATEST(0.02,
        CASE
            WHEN t.feriado_nacional AND c.codigo <= 3 THEN 0.60 + RAND() * 0.35
            WHEN t.num_dia_semana = 5 AND c.codigo <= 3 THEN 0.40 + RAND() * 0.30
            WHEN t.num_dia_semana IN (6,7) AND c.codigo <= 3 THEN 0.35 + RAND() * 0.25
            WHEN c.codigo <= 3  THEN 0.15 + RAND() * 0.30
            ELSE                     0.05 + RAND() * 0.20
        END
    )), 3) AS indice_congestion

FROM dim_tempo t
CROSS JOIN dim_trecho tr
CROSS JOIN dim_categoria_veiculo c;


-- =============================================================================
--  5. FACT_ACIDENTES
--  Geração probabilística por tipo, mês e dia da semana.
--  Resultado esperado: ~1 500–2 400 registros.
-- =============================================================================
INSERT INTO fact_acidentes
    (id_tempo, id_trecho, id_tipo_ocorrencia,
     hora_ocorrencia, qtd_veiculos_envolvidos,
     qtd_obitos, qtd_feridos_graves, qtd_feridos_leves,
     tempo_atendimento_min, tempo_liberacao_min,
     pista_molhada, condicao_tempo, periodo_dia)
SELECT
    t.id_tempo,
    tr.id_trecho,
    o.id_tipo_ocorrencia,

    /* hora da ocorrência */
    MAKETIME(
        CASE FLOOR(RAND()*4)
            WHEN 0 THEN FLOOR(RAND()*6)          -- madrugada 00-05
            WHEN 1 THEN 6  + FLOOR(RAND()*6)     -- manhã    06-11
            WHEN 2 THEN 12 + FLOOR(RAND()*6)     -- tarde    12-17
            ELSE        18 + FLOOR(RAND()*6)     -- noite    18-23
        END,
        FLOOR(RAND()*60), 0
    ),

    /* veículos envolvidos */
    CASE o.categoria
        WHEN 'Acidente'  THEN 1 + FLOOR(RAND()*3)
        WHEN 'Incidente' THEN 1 + FLOOR(RAND()*2)
        ELSE 1
    END,

    /* óbitos */
    CASE WHEN o.gravidade = 'Com óbitos'  THEN 1 + FLOOR(RAND()*2) ELSE 0 END,

    /* feridos graves */
    CASE
        WHEN o.gravidade = 'Com óbitos'  THEN FLOOR(RAND()*3)
        WHEN o.gravidade = 'Com feridos' THEN 1 + FLOOR(RAND()*3)
        ELSE 0
    END,

    /* feridos leves */
    CASE
        WHEN o.gravidade IN ('Com óbitos','Com feridos') THEN FLOOR(RAND()*4)
        ELSE 0
    END,

    /* tempo de atendimento (min) */
    CASE o.categoria
        WHEN 'Emergência' THEN  5 + FLOOR(RAND()*15)
        WHEN 'Acidente'   THEN 10 + FLOOR(RAND()*20)
        WHEN 'Incidente'  THEN 15 + FLOOR(RAND()*25)
        ELSE                   20 + FLOOR(RAND()*30)
    END,

    /* tempo de liberação da via (min) */
    CASE o.categoria
        WHEN 'Acidente'  THEN 30 + FLOOR(RAND()*90)
        WHEN 'Incidente' THEN 20 + FLOOR(RAND()*60)
        ELSE                  10 + FLOOR(RAND()*30)
    END,

    /* pista molhada — muito mais provável no verão de SP */
    CASE
        WHEN t.mes IN (11,12,1,2,3) AND RAND() < 0.45 THEN TRUE
        WHEN RAND() < 0.12 THEN TRUE
        ELSE FALSE
    END,

    /* condição do tempo */
    CASE
        WHEN t.mes IN (11,12,1,2,3) THEN
            ELT(1+FLOOR(RAND()*5),'Claro','Nublado','Chuva','Chuva','Neblina')
        WHEN t.mes IN (6,7,8) THEN
            ELT(1+FLOOR(RAND()*5),'Claro','Claro','Claro','Nublado','Neblina')
        ELSE
            ELT(1+FLOOR(RAND()*3),'Claro','Claro','Nublado')
    END,

    /* período do dia */
    ELT(1+FLOOR(RAND()*4),'Madrugada','Manhã','Tarde','Noite')

FROM dim_tempo t
CROSS JOIN dim_trecho tr
CROSS JOIN dim_tipo_ocorrencia o

-- Filtro probabilístico: inclui apenas onde sorteio < probabilidade base × amplificadores
WHERE RAND() <
    /* probabilidade base por tipo */
    CASE o.codigo
        WHEN 'IN-VE' THEN 0.025   -- veículo avariado: mais comum
        WHEN 'AC-CT' THEN 0.020   -- colisão traseira
        WHEN 'OB-OB' THEN 0.018
        WHEN 'AC-CL' THEN 0.015
        WHEN 'AC-SA' THEN 0.012
        WHEN 'AC-AF' THEN 0.010   -- fauna: típico em trechos rurais
        WHEN 'IN-CA' THEN 0.008
        WHEN 'AC-CA' THEN 0.005
        WHEN 'AC-CF' THEN 0.004
        WHEN 'AC-AT' THEN 0.003
        WHEN 'EM-IN' THEN 0.002
    END
    /* amplificador sazonal — verão = mais chuva = mais acidentes */
    * CASE WHEN t.mes IN (11,12,1,2,3)  THEN 1.50 ELSE 1.00 END
    /* amplificador fim de semana */
    * CASE WHEN t.fim_de_semana         THEN 1.30 ELSE 1.00 END
    /* amplificador feriado */
    * CASE WHEN t.feriado_nacional      THEN 1.60 ELSE 1.00 END;


-- =============================================================================
--  6. FACT_ARRECADACAO
--  ~39 190 linhas  |  1 633 dias × 3 praças × 8 categorias
--
--  Usamos tabela temporária para garantir que o volume calculado
--  (com RAND()) seja consistente entre qtd_transacoes e receita.
-- =============================================================================
DROP TEMPORARY TABLE IF EXISTS tmp_arrec;

CREATE TEMPORARY TABLE tmp_arrec AS
SELECT
    t.id_tempo,
    p.id_praca,
    c.id_categoria,
    p.tipo_sistema,

    /* volume de transações diárias — mesma lógica sazonal do tráfego leve */
    GREATEST(0, ROUND(
        CASE c.codigo
            WHEN 1 THEN 2800 WHEN 2 THEN 550  WHEN 3 THEN 160
            WHEN 4 THEN 650  WHEN 5 THEN 420  WHEN 6 THEN 280
            WHEN 7 THEN 140  WHEN 8 THEN  50
        END
        * CASE t.mes
            WHEN 1  THEN 1.45 WHEN 2  THEN 1.25 WHEN 3  THEN 1.00
            WHEN 4  THEN 0.88 WHEN 5  THEN 0.90 WHEN 6  THEN 0.95
            WHEN 7  THEN 1.30 WHEN 8  THEN 1.00 WHEN 9  THEN 1.00
            WHEN 10 THEN 1.05 WHEN 11 THEN 1.10 WHEN 12 THEN 1.35
          END
        * CASE t.num_dia_semana
            WHEN 1 THEN 0.88 WHEN 2 THEN 0.85 WHEN 3 THEN 0.87
            WHEN 4 THEN 0.95 WHEN 5 THEN 1.20 WHEN 6 THEN 1.30 WHEN 7 THEN 1.10
          END
        * CASE
            WHEN t.feriado_nacional AND c.codigo <= 3 THEN 1.55
            WHEN t.feriado_nacional AND c.codigo  > 3 THEN 0.15
            ELSE 1.00
          END
        * (0.85 + RAND() * 0.30)
    )) AS qtd_transacoes,

    /* tarifa com reajuste anual de ~6% ao ano */
    ROUND(
        CASE c.codigo
            WHEN 1 THEN  8.50 WHEN 2 THEN 12.80 WHEN 3 THEN 17.00
            WHEN 4 THEN 17.00 WHEN 5 THEN 25.50 WHEN 6 THEN 25.50
            WHEN 7 THEN 34.00 WHEN 8 THEN 34.00
        END
        * CASE YEAR(t.data) WHEN 2022 THEN 1.000
                             WHEN 2023 THEN 1.060
                             WHEN 2024 THEN 1.124
                             WHEN 2025 THEN 1.191
                             ELSE           1.262 END
    , 2) AS tarifa

FROM dim_tempo t
CROSS JOIN dim_praca_pedagio p
CROSS JOIN dim_categoria_veiculo c;


INSERT INTO fact_arrecadacao
    (id_tempo, id_praca, id_categoria,
     qtd_transacoes, qtd_isencoes,
     receita_bruta, receita_tag, receita_manual, evasao_estimada,
     tarifa_vigente)
SELECT
    id_tempo,
    id_praca,
    id_categoria,
    qtd_transacoes,
    /* isenções: ~1,5% das transações (deficientes, emergências) */
    GREATEST(0, ROUND(qtd_transacoes * 0.015)),

    /* receita bruta */
    ROUND(qtd_transacoes * tarifa, 2),

    /* receita via tag/AVI — varia pelo tipo de sistema da praça */
    ROUND(qtd_transacoes * tarifa *
        CASE tipo_sistema
            WHEN 'Free-Flow' THEN 0.95
            WHEN 'Híbrido'   THEN 0.65
            ELSE 0.30
        END, 2),

    /* receita manual (dinheiro/cartão no caixa) */
    ROUND(qtd_transacoes * tarifa *
        CASE tipo_sistema
            WHEN 'Free-Flow' THEN 0.02
            WHEN 'Híbrido'   THEN 0.32
            ELSE 0.67
        END, 2),

    /* evasão estimada — free-flow tem maior índice */
    ROUND(qtd_transacoes * tarifa *
        CASE tipo_sistema
            WHEN 'Free-Flow' THEN 0.030
            WHEN 'Híbrido'   THEN 0.012
            ELSE 0.003
        END, 2),

    tarifa
FROM tmp_arrec;

DROP TEMPORARY TABLE IF EXISTS tmp_arrec;


-- =============================================================================
--  7. FACT_MANUTENCAO
--  Geração probabilística por tipo, estação e trecho.
--  Resultado esperado: ~450–900 ordens de serviço.
--
--  Regras sazonais:
--    • Preventiva: concentrada no período seco (abr–set)
--    • Corretiva : pico após chuvas (mar–mai)
--    • Emergencial: pico no verão (nov–mar)
-- =============================================================================
DROP TEMPORARY TABLE IF EXISTS tmp_man;

CREATE TEMPORARY TABLE tmp_man AS
SELECT
    t.id_tempo,
    t.data              AS dt_inicio,
    tr.id_trecho,
    tr.extensao_km,
    m.id_tipo_manutencao,
    m.criticidade,
    m.grupo,

    /* duração em dias */
    CASE m.criticidade
        WHEN 'Preventiva'  THEN 3  + FLOOR(RAND()*12)
        WHEN 'Corretiva'   THEN 1  + FLOOR(RAND()*7)
        WHEN 'Emergencial' THEN    FLOOR(RAND()*3)
    END AS dias,

    /* extensão tratada (km) */
    CASE m.grupo
        WHEN 'Pavimento'   THEN ROUND(0.5 + RAND()*3.0, 3)
        WHEN 'Drenagem'    THEN ROUND(0.2 + RAND()*2.0, 3)
        WHEN 'Sinalização' THEN ROUND(0.5 + RAND()*5.0, 3)
        WHEN 'Estruturas'  THEN ROUND(0.1 + RAND()*0.5, 3)
        WHEN 'Vegetação'   THEN ROUND(1.0 + RAND()*8.0, 3)
        WHEN 'Elétrica'    THEN ROUND(0.3 + RAND()*3.0, 3)
        ELSE ROUND(0.5 + RAND()*2.0, 3)
    END AS ext_km,

    /* custo por km tratado (R$) */
    CASE m.grupo
        WHEN 'Pavimento'   THEN 180000 + RAND()*120000
        WHEN 'Drenagem'    THEN  30000 + RAND()* 20000
        WHEN 'Sinalização' THEN  15000 + RAND()* 10000
        WHEN 'Estruturas'  THEN 400000 + RAND()*300000
        WHEN 'Vegetação'   THEN   5000 + RAND()*  3000
        WHEN 'Elétrica'    THEN  25000 + RAND()* 15000
        ELSE                     50000 + RAND()* 30000
    END AS custo_km,

    /* IGP antes e depois */
    ROUND(30 + RAND()*50, 2) AS igp_antes,
    ROUND( 5 + RAND()*20, 2) AS igp_depois,

    /* precipitação acumulada nos 30 dias anteriores (mm) */
    CASE
        WHEN t.mes IN (11,12,1,2,3) THEN ROUND( 80 + RAND()*180, 1)
        WHEN t.mes IN (6,7,8)       THEN ROUND( 10 + RAND()* 40, 1)
        ELSE                             ROUND( 30 + RAND()* 80, 1)
    END AS chuvas_mm

FROM dim_tempo t
CROSS JOIN dim_trecho tr
CROSS JOIN dim_tipo_manutencao m

WHERE
    /* ordens iniciam apenas às segundas-feiras */
    t.num_dia_semana = 1

    AND RAND() <
        /* probabilidade por criticidade e mês */
        CASE m.criticidade
            WHEN 'Preventiva' THEN
                CASE WHEN t.mes IN (4,5,6,7,8,9) THEN 0.08 ELSE 0.025 END
            WHEN 'Corretiva' THEN
                CASE WHEN t.mes IN (3,4,5) THEN 0.12 ELSE 0.04 END
            WHEN 'Emergencial' THEN
                CASE WHEN t.mes IN (11,12,1,2,3) THEN 0.04 ELSE 0.010 END
        END

        /* emergencial pode acontecer qualquer dia — corrige filtro de segunda */
        * CASE m.criticidade WHEN 'Emergencial' THEN 7 ELSE 1 END;


INSERT INTO fact_manutencao
    (id_tempo, id_trecho, id_tipo_manutencao,
     data_conclusao, dias_intervencao, extensao_tratada_km,
     custo_material, custo_mao_obra, custo_equipamento, custo_total,
     igp_antes, igp_depois, chuvas_ultimos_30d_mm, origem)
SELECT
    id_tempo,
    id_trecho,
    id_tipo_manutencao,
    DATE_ADD(dt_inicio, INTERVAL dias DAY),
    dias,
    ext_km,
    ROUND(ext_km * custo_km * 0.40, 2),   -- material  40%
    ROUND(ext_km * custo_km * 0.35, 2),   -- mão de obra 35%
    ROUND(ext_km * custo_km * 0.25, 2),   -- equipamento 25%
    ROUND(ext_km * custo_km       , 2),   -- total
    igp_antes,
    igp_depois,
    chuvas_mm,
    CASE criticidade
        WHEN 'Preventiva'  THEN 'Programada'
        WHEN 'Corretiva'   THEN 'Corretiva'
        WHEN 'Emergencial' THEN 'Emergencial'
    END
FROM tmp_man;

DROP TEMPORARY TABLE IF EXISTS tmp_man;


-- =============================================================================
--  VERIFICAÇÃO RÁPIDA — volumes carregados por tabela
-- =============================================================================
SELECT 'dim_tempo'        AS tabela, COUNT(*) AS registros FROM dim_tempo
UNION ALL
SELECT 'dim_trecho',       COUNT(*) FROM dim_trecho
UNION ALL
SELECT 'dim_praca_pedagio',COUNT(*) FROM dim_praca_pedagio
UNION ALL
SELECT 'fact_trafego',     COUNT(*) FROM fact_trafego
UNION ALL
SELECT 'fact_acidentes',   COUNT(*) FROM fact_acidentes
UNION ALL
SELECT 'fact_arrecadacao', COUNT(*) FROM fact_arrecadacao
UNION ALL
SELECT 'fact_manutencao',  COUNT(*) FROM fact_manutencao;


SET FOREIGN_KEY_CHECKS = 1;

-- FIM DO SCRIPT DE POPULAÇÃO
