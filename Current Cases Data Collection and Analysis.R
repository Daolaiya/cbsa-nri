# Analysis of existing Cases ----------------------------------------------
library(DBI)
library(tidyverse)
library(dbplyr)
library(odbc)
library(readxl)
library(duckplyr)
library(duckplyr)

n <- dbDriver("odbc")

connect <- dbConnect(odbc::odbc(),
                     Driver = "NetezzaSQL",
                     Server = "ec63ap5692",
                     Database = "DWP1",
                     Port = "5480",
                     uid = rstudioapi::askForPassword("User Name"),
                     pwd = rstudioapi::askForPassword("Password"))

yesterday <- Sys.Date() - 1

# Contextual Data ---------------------------------------------------------
setwd("Y:/INTEL/TF-TBML COE")
based_index <- read_xlsx("Contextual Data.xlsx", sheet = "Basel Index")

# Commercial Type Codes ---------------------------------------------------
setwd("Y:/INTEL/TF-TBML COE/Data Analytics")
comm_codes <- read_excel("Commercial Type Codes.xlsx", sheet = "AX Related Party TypeCode")

comm_codes <- comm_codes %>%
  separate_longer_delim(RLTD_PTY_TCDE, delim = "or") %>%
  mutate(PTY_TCDE = trimws(RLTD_PTY_TCDE)) %>%
  select(PTY_TCDE, DESCRIPTION) %>%
  na.omit()

parties <- unique(comm_codes$DESCRIPTION)

# Load current data -------------------------------------------------------
setwd("Y:/INTEL/TF-TBML COE/Data Analytics/Indicator Analysis (Current Cases)")
current_cases <- read_excel("BNs From Cases.xlsx")
bns <- as.numeric(current_cases$`BN number`)
bns <- bns[!(bns %in% 790356083)]

# Load Accounting ---------------------------------------------------------
accounting <- read_csv_duckdb("Current Cases - EFIRM.csv", prudence = "lavish", options = list(nullstr = "null"))

accounting %>%
  mutate(BN = str_extract(Importer_ID, "[0-9]{9}")) %>%
  count(BN, sort = TRUE) %>%
  mutate(percent = n/sum(n)) # Border Buddy accounts for 95.5% of cases. Let's remove them from the analysis.

accounting <- accounting %>%
  filter(!str_detect(Importer_ID, "790356083"))

# Cers --------------------------------------------------------------------
cers <- read_excel("Current Cases - CERS.xlsx")

cers <- cers %>%
  filter(!is.na(`Trade Document ID`))

# One to One --------------------------------------------------------------
one_to_one <- read_csv("One_to_One_Current_Cases.csv")

# Other Indicators --------------------------------------------------------
setwd("Y:/INTEL/TF-TBML COE/Data Analytics/Indicator Analysis (Current Cases)/Indicators")
files <- list.files()
data_list <- lapply(files, read_excel)
other_indicators <- Reduce(function(x, y) left_join(x, y, by = "importer_id"), data_list)

# Across Query and Structure ----------------------------------------------
# Keys --------------------------------------------------------------------
keys_non_iid <- c("DRV_REQ_NBR", "AX_CLNT_NBR", "SBRN_PGM_ID", "SBRN_PGM_ACNT_NBR", "SO_ID", "REQ_VERS_NBR")
keys_iid <- append(keys_non_iid, c("CMRC_INVC_NBR", "GAGI_NBR", "GDS_ITM_NBR"))
keys_invoice <- append(keys_non_iid, c("CMRC_INVC_NBR"))
keys_gagi <- append(keys_non_iid, c("CMRC_INVC_NBR", "GAGI_NBR"))

# Tables ------------------------------------------------------------------
root <- tbl(connect, in_schema("DW_AX", "TCRROO1")) %>%
filter(as_date(AUDT_INS_TSTMP) <= yesterday,
       as_date(AUDT_INS_TSTMP) >= "2018-01-01",
       AX_CLNT_NBR %in% bns,
       SO_ID == "911") %>%
select(any_of(keys_non_iid), EXT_CUS_CLNT_ID, CLNT_SPLY_REQ_ID, AUDT_INS_TSTMP) %>%
compute(name = in_catalog("DWP1","OADM","TBML_ROOT_TEMP"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

iid_party <- tbl(connect, in_schema("DW_AX", "TCRSGPY")) %>%
  filter(AX_CLNT_NBR %in% bns) %>%
  select(any_of(keys_non_iid), PTY_TCDE, PTY_ID, RLTD_PTY_NM_LN1, RLTD_PTY_NM_LN2,
         RLTD_PTY_NM_LN3, ADDR_LN1, ADDR_LN2, ADDR_LN3, CTY_NM, PSTL_ZIP_CDE, PROV_ST_CDE, CNTRY_CDE) %>%
  compute(name = in_catalog("DWP1","OADM","TBML_IID_PTY_TEMP"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

gov_agny_gds_srce <- tbl(connect, in_schema("DW_AX", "TCRSGCD")) %>%
  filter(AX_CLNT_NBR %in% bns) %>%
  select(any_of(keys_iid), CNTRY_ORIG_CDE, STE_ORIG_CDE) %>%
  compute(name = in_catalog("DWP1","OADM","TBML_GDS_SOURCE_TEMP"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

invoice <- tbl(connect, in_schema("DW_AX", "TCRCMIV")) %>%
  filter(AX_CLNT_NBR %in% bns) %>%
  select(any_of(keys_invoice), CMRC_INVC_QTY, INVC_QTY_UOM_CDE, CMRC_INVC_WT_VOL, INVC_WT_UOM_CDE, INVC_TAMT, TAMT_CURCY_CDE) %>%
  compute(name = in_catalog("DWP1","OADM","TBML_INVOICE_TEMP"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

gov_gds_itm_detail <- tbl(connect, in_schema("DW_AX", "TCRSGGI")) %>%
  filter(AX_CLNT_NBR %in% bns) %>%
  select(any_of(keys_iid), GDS_CNTRY_ORIG_CDE, GDS_ST_PROV_CDE) %>%
  compute(name = in_catalog("DWP1","OADM","TBML_ITM_DTL_TEMP"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

inv_country <- tbl(connect, in_schema("DW_AX", "TCRSGIC")) %>%
  filter(AX_CLNT_NBR %in% bns) %>%
  select(any_of(keys_invoice), INVC_CNTRY_CDE, INVC_ST_CDE, DPRT_DT) %>%
  compute(name = in_catalog("DWP1","OADM","TBML_INV_CTY_TEMP"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

iid_gds_itm_desc <- tbl(connect, in_schema("DW_AX", "TCRSGIT")) %>%
  filter(AX_CLNT_NBR %in% bns) %>%
  select(any_of(keys_iid), CLASS_CDE, ITM_DESC_TXT, ITM_CHAR_SQNBR) %>%
  compute(name = in_catalog("DWP1","OADM","TBML_ITM_DSC_TEMP"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

shpmnt_rls_pck <- tbl(connect, in_schema("DW_AX", "TCRSHRP")) %>%
  filter(AX_CLNT_NBR %in% bns) %>%
  select(any_of(keys_non_iid), NET_WT, NET_WT_UOM_CDE, GRO_WT, GRO_WT_UOM_CDE, TTL_TRANS_VAL) %>%
  compute(name = in_catalog("DWP1","OADM","TBML_SHP_RLS_TEMP"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

gvt_price <- tbl(connect, in_schema("DW_AX", "TCRSGPC")) %>%
  filter(AX_CLNT_NBR %in% bns) %>%
  select(any_of(keys_iid), PRICE_TCDE, PRICE_VAL, PRICE_CRNCY_CDE) %>%
  compute(name = in_catalog("DWP1","OADM","TBML_GVT_PRC_TEMP"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

gvt_pkg_qty <- tbl(connect, in_schema("DW_AX", "TCRSGPK")) %>%
  filter(AX_CLNT_NBR %in% bns) %>%
  select(any_of(keys_iid), UN_PKG_TCDE, QTY) %>%
  compute(name = in_catalog("DWP1","OADM","TBML_PKG_QTY_TEMP"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

gvt_pkg_cnt <- tbl(connect, in_schema("DW_AX", "TCRSGCM")) %>%
  filter(AX_CLNT_NBR %in% bns) %>%
  select(any_of(keys_iid), MSR_UNIT_TCDE, UNIT_CNT, PKG_UN_TCDE, PKG_QTY) %>%
  compute(name = in_catalog("DWP1","OADM","TBML_PKG_CNT_TEMP"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

# Query -------------------------------------------------------------------
setwd("Y:/INTEL/TF-TBML COE/Data Analytics/Indicator Analysis (Current Cases)")

release <- gov_agny_gds_srce %>%
  left_join(iid_gds_itm_desc, by = keys_iid, keep = FALSE) %>%## Add compute at each stage
  left_join(gvt_pkg_cnt, by = keys_iid, keep = FALSE) %>%
  compute(name = in_catalog("DWP1","OADM","TBML_ALL_CASES_TEMP"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

release_1 <- release %>%
  left_join(gvt_price, by = keys_iid, keep = FALSE) %>%
  left_join(gvt_pkg_qty, by = keys_gagi, keep = F) %>%
  left_join(invoice, by = keys_invoice, keep = FALSE) %>%
  compute(name = in_catalog("DWP1","OADM","TBML_ALL_CASES_TEMP_1"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

release_2 <- release_1 %>%
  left_join(inv_country, by = keys_invoice, keep = FALSE ) %>%
  compute(name = in_catalog("DWP1","OADM","TBML_ALL_CASES_TEMP_2"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

# Drop temp and temp 2
dbRemoveTable(conn = connect , Id("OADM", "TBML_ALL_CASES_TEMP"))
dbRemoveTable(conn = connect , Id("OADM", "TBML_ALL_CASES_TEMP_1"))

release_3 <- release_2 %>%
  left_join(iid_party, by = keys_non_iid, keep = F) %>%
  compute(name = in_catalog("DWP1","OADM","TBML_ALL_CASES_TEMP_3"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

release_4 <- release_3 %>%
  left_join(shpmnt_rls_pck, by = keys_non_iid, keep = F) %>%
  compute(name = in_catalog("DWP1","OADM","TBML_ALL_CASES_TEMP_4"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

release_5 <- release_4 %>%
  right_join(root, by = keys_non_iid, keep = F) %>%
  compute(name = in_catalog("DWP1","OADM","TBML_ALL_CASES_TEMP_5"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

release_6 <- release_5 %>%
  group_by(DRV_REQ_NBR, CMRC_INVC_NBR, GAGI_NBR, GDS_ITM_NBR) %>%
  slice_max(REQ_VERS_NBR, n = 1) %>%
  ungroup() %>%
  compute(name = in_catalog("DWP1","OADM","TBML_ALL_CASES_TEMP_6"), analyze = FALSE, overwrite = TRUE, temporary = FALSE)

# Collect the Results and Manipulate --------------------------------------
cases_release <- release_6 %>%
  collect() %>%
  group_by(DRV_REQ_NBR, CMRC_INVC_NBR, GAGI_NBR, GDS_ITM_NBR) %>%
  fill(CLASS_CDE, DPRT_DT, ITM_DESC_TXT, INVC_CNTRY_CDE, INVC_ST_CDE, CLNT_SPLY_REQ_ID, .direction = "downup") %>%
  distinct(PTY_TCDE, PRICE_TCDE, .keep_all = TRUE) %>%
  ungroup() %>%
  mutate(PRICE_TCDE = trimws(PRICE_TCDE),
         PRICE_TCDE = if_else(PRICE_TCDE == "66", true = "Total", false = "PPU")) %>%
  mutate(PTY_TCDE = trimws(PTY_TCDE)) %>%
  left_join(comm_codes, by = "PTY_TCDE") %>%
  mutate(PTY_TCDE = DESCRIPTION) %>%
  select(-DESCRIPTION) %>%
  pivot_wider(names_from = PRICE_TCDE, values_from = PRICE_VAL, names_prefix = "Invoice_") %>%
  group_by(CLNT_SPLY_REQ_ID, CMRC_INVC_NBR, GAGI_NBR, GDS_ITM_NBR) %>%
  fill(Invoice_Total, Invoice_PPU, .direction = "downup") %>%
  ungroup() %>%
  distinct(PTY_TCDE,CMRC_INVC_NBR, CLNT_SPLY_REQ_ID, GAGI_NBR, GDS_ITM_NBR, .keep_all = TRUE) %>%
  mutate(across(.cols = starts_with("RLTD_PTY_NM"), ~str_replace_na(.x, " ")),
         across(.cols = starts_with("ADDR_LN"), ~str_replace_na(.x, " "))) %>%
  mutate(RLTD_PTY_NM = str_c(RLTD_PTY_NM_LN1, RLTD_PTY_NM_LN2, RLTD_PTY_NM_LN3),
         ADDR = str_c(ADDR_LN1, ADDR_LN2, ADDR_LN3)) %>%
  select(-RLTD_PTY_NM_LN1, -RLTD_PTY_NM_LN2, -RLTD_PTY_NM_LN3, -ADDR_LN1, -ADDR_LN2, -ADDR_LN3) %>%
  pivot_wider(names_from = PTY_TCDE, values_from = c("RLTD_PTY_NM", "ADDR", "CTY_NM", "PSTL_ZIP_CDE", 
                                                     "PROV_ST_CDE", "CNTRY_CDE", "PTY_ID")) %>%
  group_by(CLNT_SPLY_REQ_ID,CMRC_INVC_NBR, GAGI_NBR, GDS_ITM_NBR) %>%
  fill(ends_with(parties), .direction = "downup") %>%
  ungroup() %>%
  relocate(ends_with(parties), .after = last_col()) %>%
  distinct(CLNT_SPLY_REQ_ID, CMRC_INVC_NBR, GAGI_NBR, GDS_ITM_NBR, .keep_all = TRUE) %>%
  mutate(CLNT_SPLY_REQ_ID = trimws(CLNT_SPLY_REQ_ID),
         CLASS_CDE = trimws(CLASS_CDE))

setwd("Y:/INTEL/TF-TBML COE/Data Analytics/Indicator Analysis (Current Cases)")
write_csv(cases_release, "Release (Current Cases).csv")

# Analysis ----------------------------------------------------------------
current_companies <- accounting %>%
  select(starts_with("Importer")) %>%
  mutate(bn = str_extract(Importer_ID, "^\\d{9}")) %>%
  distinct(bn, .keep_all = T)

miscalculations <- cases_release %>%
  mutate(Expected_total = Invoice_PPU * UNIT_CNT) %>%
  mutate(inconsistent_price = !near(Expected_total, Invoice_Total)) %>%
  filter(inconsistent_price == TRUE) %>%
  distinct(AX_CLNT_NBR) %>%
  mutate(miscalculations = TRUE,
         AX_CLNT_NBR = as.character(AX_CLNT_NBR))

ppu_diff <- cases_release %>%
  arrange(AX_CLNT_NBR, AUDT_INS_TSTMP) %>%
  group_by(AX_CLNT_NBR, CLASS_CDE, MSR_UNIT_TCDE) %>%
  mutate(
    Prev_PPU = lag(Invoice_PPU), 
    Price_Diff = Prev_PPU - Invoice_PPU
  ) %>%
  select(Invoice_PPU, Prev_PPU, Price_Diff) 

inconsistent_prices <- ppu_diff %>%
  ungroup() %>%
  filter(!is.na(Price_Diff) | Price_Diff != 0) %>%
  distinct(AX_CLNT_NBR) %>%
  mutate(inconsistent_values = TRUE,
         AX_CLNT_NBR = as.character(AX_CLNT_NBR))

current_companies_0 <- current_companies %>%
  left_join(miscalculations, by = c("bn" = "AX_CLNT_NBR")) %>%
  left_join(inconsistent_prices, by = c("bn" = "AX_CLNT_NBR"))

# 3. Numbered Companies ------------------------------------------------------
current_companies_1 <- current_companies_0 %>%
  mutate(numbered_company = str_detect(Importer_Name, "^[[:digit:]]{4}")) %>%
  mutate(has_trade = TRUE)

# 4. and 5. Benford's Law Tests -----------------------------------------------------
library(BenfordTests)

e_firm_benftest <- accounting %>%
  mutate(BN = str_extract(Importer_ID, "^\\d{9}")) %>%
  select(BN, Value_Currency_Conversion)

cers_benftest <- cers %>%
  mutate(BN = str_extract(`Tombstone - Exporter BN15`, "^\\d{9}")) %>%
  select(BN, Value_Currency_Conversion = `Total Commodity Value`)

all_values <- bind_rows(e_firm_benftest, cers_benftest)

# Functions
run_benford_test_imports_1st_digit <- function(data) {
  test_result_1st_digit  <- ks.benftest(data$Value_Currency_Conversion, digit = 1)
  tibble(
    statistic_1st_digit = test_result_1st_digit$statistic,
    p.value_1st_digit = test_result_1st_digit$p.value
  )
}

run_benford_test_imports_2nd_digit <- function(data) {
  test_result_2nd_digit  <- ks.benftest(data$Value_Currency_Conversion, digit = 2)
  tibble(
    statistic_2nd_digit = test_result_2nd_digit$statistic,
    p.value_2nd_digit = test_result_2nd_digit$p.value
  )
}

# Imports
e_firm_benftest_results_1st_digit <- all_values %>%
  group_by(BN) %>%
  group_modify(~run_benford_test_imports_1st_digit(.x)) %>%
  ungroup() %>%
  mutate(does_not_conform_benford_ks_1st_digit = if_else(p.value_1st_digit <= 0.05, true = TRUE, false = FALSE))

e_firm_benftest_results <- all_values %>%
  group_by(BN) %>%
  group_modify(~run_benford_test_imports_2nd_digit(.x)) %>%
  ungroup() %>%
  mutate(does_not_conform_benford_ks_2nd_digit = if_else(p.value_2nd_digit <= 0.05, true = TRUE, false = FALSE)) %>%
  bind_cols(e_firm_benftest_results_1st_digit) %>%
  select(BN = `BN...1`, contains("1st"), contains("2nd"))

# Bind Results ------------------------------------------------------------
current_companies_2 <- current_companies_1 %>%
  left_join(e_firm_benftest_results, by = c("bn" = "BN")) %>%
  select(-starts_with("statistic"), - starts_with("p.value"))

# 6. One to One Analysis -----------------------------------------------------
one_to_one <- one_to_one %>%
  mutate(importer = as.character(importer),
         has_1_to_1_relationship = TRUE) %>%
  select(importer, has_1_to_1_relationship)

current_companies_3 <- current_companies_2 %>%
  left_join(one_to_one, by = c("bn" = "importer"))

# 7. High Risk ---------------------------------------------------------------
high_risk_countries_imports <- accounting %>%
  left_join(based_index, by = c("Country_of_Export" = "ISO Code" )) %>%
  filter(Basel_ML_TF_RISK >= 5.5) %>%
  mutate(BN = str_extract(Importer_ID, "^\\d{9}")) %>%
  distinct(BN) %>%
  mutate(trades_with_high_risk_jurisdictions = TRUE)

current_companies_4 <- current_companies_3 %>%
  left_join(high_risk_countries_imports, by = c("bn" = "BN")) %>%
  mutate(trades_with_high_risk_jurisdictions = replace_na(trades_with_high_risk_jurisdictions, FALSE))

# 8., 9., 10., 11., Other Indicators --------------------------------------------------------
current_companies_5 <- other_indicators %>%
  mutate(high_dormancy = if_else(percentile_range.x == "Above 75th percentile",
                                 true = TRUE, false = FALSE)) %>%
  mutate(rounded_transactions = if_else(num_rounded_transactions > 1,
                                        true = TRUE, false = FALSE)) %>%
  mutate(high_first_transaction = if_else(percentile_range.y == "Above 75th percentile", 
                                          true = T, false = F)) %>%
  mutate(inconsistent_lines_of_trade = if_else(num_sections > 1, 
                                               true = TRUE, false = FALSE)) %>%
  distinct(Importer_ID = importer_id, high_dormancy, rounded_transactions,
           high_first_transaction, inconsistent_lines_of_trade) %>%
  mutate(across(2:5, ~ replace_na(.x, FALSE))) %>%
  right_join(current_companies_4) %>%
  relocate(high_dormancy:inconsistent_lines_of_trade, .after = "does_not_conform_benford_ks_2nd_digit")

# 12. Vague Description of Goods ---------------------------------------------
library(quanteda)
library(quanteda.textstats)

cers_txt <- cers %>%
  mutate(AX_CLNT_NBR = str_extract(`Tombstone - Exporter BN15`, "^\\d{9}")) %>%
  select(CLNT_SPLY_REQ_ID = `Proof of Report Number`, AX_CLNT_NBR, ITM_DESC_TXT = `Cargo Description`)

all_txt <- cases_release %>%
  mutate(across(all_of(c("CLNT_SPLY_REQ_ID", "AX_CLNT_NBR")), ~ as.character(.))) %>%
  select(CLNT_SPLY_REQ_ID, AX_CLNT_NBR, ITM_DESC_TXT) %>%
  bind_rows(cers_txt)

goods_descriptions <- corpus(all_txt, text_field = "ITM_DESC_TXT")
goods_tokens <- tokens(goods_descriptions, remove_punct = TRUE, remove_numbers = TRUE)
description_stats <- textstat_summary(goods_descriptions)
summary(description_stats) 

vague_descriptions_imports <- description_stats %>%
  mutate(vague_description = if_else(tokens < 3 & chars <= 13, 
                                     true = TRUE, false = FALSE)) %>%
  bind_cols(all_txt) %>%
  group_by(AX_CLNT_NBR) %>%
  summarize(prop_vague = sum(vague_description) / n(),
            row_count = n()) %>%
  ungroup() %>%
  mutate(has_vague_descriptions = if_else(prop_vague >= 0.05,
                                          true = TRUE, false = FALSE),
         AX_CLNT_NBR = as.character(AX_CLNT_NBR))

current_companies_6 <- current_companies_5 %>%
  left_join(vague_descriptions_imports, by = c("bn" = "AX_CLNT_NBR")) %>%
  select(-prop_vague, -row_count) %>%
  mutate(has_vague_descriptions = replace_na(has_vague_descriptions, FALSE))

# Final Analysis ----------------------------------------------------------
final_all_cases <- current_companies_6 %>%
  mutate(across(.cols = miscalculations:has_vague_descriptions, ~ replace_na(., FALSE))) %>%
  mutate(total_indicators = base::rowSums(select(., miscalculations:has_vague_descriptions), na.rm = TRUE)) %>%
  mutate(proportion_of_indicators = total_indicators / 13)

# Writing the excel document ----------------------------------------------
writexl::write_xlsx(final_all_cases, "All Cases Analysis.xlsx")
