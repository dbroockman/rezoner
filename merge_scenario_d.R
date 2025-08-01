######### Load libraries ##########
library(readr)
library(readxl)
library(dplyr)
library(tidyr)
library(modelr)
library(caret)
library(sf)
library(sfarrow)
source('./constants.R')

merge_scenario <- function() {

######### Create a dataset for the Fall 2023 rezoning #############
map4 <- st_read(file.path(PROJECT_DIR, 'Fall2023Rezoning.json'), promote_to_multi=F)
map5 <- st_read(file.path(PROJECT_DIR, 'rezone_sites_1_2024.geojson'), promote_to_multi=F)
map6 <- st_read(file.path(PROJECT_DIR, 'data/rezone_sites_5_2025.geojson'), promote_to_multi=F)
map5 <- st_transform(map5, st_crs(map4))
map6 <- st_transform(map6, st_crs(map4))


# The above dataset lacks info on the fourplex rezoning, so I have to separately
# load the block-level dataset on where fourplexes are allowed now.
fourplex <- st_read(file.path(PROJECT_DIR, 'fourplex_areas_12_2023.geojson'))
fourplex <- st_transform(fourplex, st_crs(map4))

corner <- st_read(file.path(PROJECT_DIR, 'data/Parcels_Corner.geojson'))
corner <- st_transform(corner, st_crs(map4))

map4 <- map4 %>% mutate(ACRES = round(Shape__Area / 43560, 3))
map5 <- map5 %>% mutate(ACRES = round(Shape__Area / 43560, 3))
map6 <- map6 %>% mutate(ACRES = round(Shape__Area / 43560, 3))

map4 <- map4 %>%
  mutate(M4_ZONING = ifelse(grepl("Unchanged", HeightText), NA, HeightText)) %>%
  rename(M4_height = HeightInteger) %>%
  select(-HeightText, -OBJECTID, -Shape__Area, -Shape__Length)


map5 <- map5 %>%
  mutate(M5_ZONING = ifelse(grepl("Unchanged", NEW_HEIGHT), NA, NEW_HEIGHT)) %>%
  rename(M5_height = NEW_HEIGHT_NUM) %>%
  select(-NEW_HEIGHT, -OBJECTID, -Shape__Area, -Shape__Length)

map6 <- map6 %>%
  mutate(M6_ZONING_local = NEW_HEIGHT) %>%
  mutate(M6_height_local = as.numeric(str_extract(map6$NEW_HEIGHT, "\\d+"))) %>%
  mutate(M6_height_base = as.numeric(str_extract(map6$Base, "\\d+"))) %>%
  mutate(M6_ZONING_base = as.numeric(str_extract(map6$Base, "\\d+"))) %>%
  select(-NEW_HEIGHT, -OBJECTID, -height, -Shape__Area, -Shape__Length)

# Only keep the numbers for base zoning for parcels that actually got base density upzoned in the June 2025 plan
map6$M6_ZONING_base[map6$M6_ZONING_local == "Density decontrol only"] <- NA
map6$M6_ZONING_base[map6$M6_ZONING_local == "40' Height Allowed"] <- NA
map6$M6_ZONING_base[map6$M6_height_base == map6$gen_hght] <- NA
map6$M6_ZONING_local[map6$M6_ZONING_local == "Density decontrol, unchanged height"] <- "40' Height Allowed"


map4 <- map4[!duplicated(map4), ]
map5 <- map5[!duplicated(map5), ]
map6 <- map6[!duplicated(map6), ]

# map4 %>%
#   group_by(mapblklot, ACRES) %>%
#   filter(!(is.na(M4_ZONING) & n() > 1)) %>%
#   ungroup() %>%
#   nrow()

new_map <- full_join(as.data.frame(map5), 
                      as.data.frame(map4[!is.na(map4$M4_ZONING),]),
                      by=c('mapblklot', 'ACRES'),
                      suffix=c('map5', 'map4'))
new_map <- full_join(new_map, 
                     as.data.frame(map6[!is.na(map6$M6_ZONING_local) | !is.na(map6$M6_ZONING_base),]),
                     by=c('mapblklot', 'ACRES'),
                     suffix=c('', 'map6'))
new_map <- rename(new_map,'geometrymap6' = 'geometry')

new_map$geometry <- new_map$geometrymap5

# Replace empty geometries from geometrymap5 with geometrymap4
empty_idx <- st_is_empty(new_map$geometry)
new_map$geometry[empty_idx] <- new_map$geometrymap4[empty_idx]

# Now, for any still empty geometries, replace them with geometrymap6
empty_idx <- st_is_empty(new_map$geometry)
new_map$geometry[empty_idx] <- new_map$geometrymap6[empty_idx]

# Remove the temporary geometry columns and convert to sf
new_map <- new_map %>%
  select(-geometrymap4, -geometrymap5, -geometrymap6) %>%
  st_as_sf(crs = st_crs(map4))

######### Load and clean sites inventory dataset #############
sf_sites_inventory <- read_excel(file.path(PROJECT_DIR, 'sf-sites-inventory-form-Dec-2022 - Copy.xlsx'), 
                                 sheet = "Table B -Submitted-Dec-22", 
                                 skip=1, 
                                 na='n/a')
# I need a spatial join to merge the Fall 2023 dataset with the sites inventory 
# dataset. Hence, I'm first joining the sites inventory with a geospatial 
# bluesky dataset.
sf_history <- readRDS(file.path(PROJECT_DIR, './data/geobluesky.RDS'))
sf_history <- st_transform(sf_history, crs=st_crs(map4))

# Clean and join
sf_sites_inventory <- mutate(sf_sites_inventory,
             MapBlkLot_Master = stringr::str_replace(mapblklot, "-", ""),
             year = 2016) %>%
  select(-mapblklot) %>%
  distinct(MapBlkLot_Master, .keep_all = TRUE)

# Add blue sky variables to sf_sites_inventory
df <- sf_history %>%
  as.data.frame() %>%
  filter(year == 2016) %>%
  left_join(sf_sites_inventory, by = c('MapBlkLot_Master', "year")) %>%
  st_sf(crs=st_crs(map4))

# Dropping 20 needless columns
df <- df[ , !grepl("(_VLI|_LI|_M|_AM)$", colnames(df))]
to_drop <- c('JURISDICT', 'ZIP5', 'SHORTFALL', 'MIN_DENS', 
             'SS_MAP1', 'SS_MAP2', 'SS_MAP3', 'INFRA')
df <- df[ , !(colnames(df) %in% to_drop)]

######### Merge sites inventory and fall 2023 rezoning dataframes #########
# Merge first on mapblklot where possible
merge1 <- inner_join(new_map, 
                     st_drop_geometry(df),
                     by = 'mapblklot')
nrow(merge1)
nrow(new_map)

# Merge remaining spatially
unmerged <- new_map[!(new_map$mapblklot %in% merge1$mapblklot),]
merge2 <- st_join(unmerged, df, left = F, largest=T)

# # I assume other parcels are primarily fourplexes... but no
# unmerged2 <- unmerged[!(unmerged$mapblklot %in% merge2$mapblklot),]
# table(unmerged2$M4_ZONING)
# 
# m4_needed <- new_map[(!is.na(new_map$M4_ZONING) | !is.na(new_map$M5_ZONING))
#                      & (new_map$mapblklot %in% unmerged2$mapblklot),]
# merge3 <- st_join(m4_needed, df, left=F, largest=T)
# #unmerged3 <- unmerged2[!(unmerged2$mapblklot %in% merge3$mapblklot),]


merge1 <- merge1 %>% 
  rename(ACRES = ACRES.x) %>%
  select(-ACRES.y)
merge2 <- merge2 %>% 
  rename(ACRES = ACRES.x, mapblklot = mapblklot.x) %>%
  select(-ACRES.y, -mapblklot.y) 
# merge3 <- merge3 %>% 
#    rename(ACRES = ACRES.x, mapblklot = mapblklot.x) %>%
#    select(-ACRES.y, -mapblklot.y)

final <- rbind(merge1, merge2) #, merge3) #, merge4)
#final <- plyr::rbind.fill(merge3, final)

# Incorporate fourplex zoning to Fall 2023 rezoning dataset
fourplex_description <- "Increased density up to four units"
intersections <- st_join(final[is.na(final$M4_ZONING),], fourplex, left=F)
final$M4_ZONING[
  (final$mapblklot %in% intersections$mapblklot) 
  & is.na(final$M4_ZONING)
] <- fourplex_description
intersections <- st_join(final[is.na(final$M5_ZONING),], fourplex, left=F)
final$M5_ZONING[
  (final$mapblklot %in% intersections$mapblklot) 
  & is.na(final$M5_ZONING)
] <- fourplex_description
intersections <- st_join(final[is.na(final$M6_ZONING_base),], fourplex, left=F)
final$M6_ZONING_base[
  (final$mapblklot %in% intersections$mapblklot) 
  & is.na(final$M6_ZONING_base)
] <- fourplex_description

fourOrSixPlex = 'Increased density up to four units (six units on corner lots)'
final[!is.na(final$M1_ZONING) & final$M1_ZONING == fourOrSixPlex, 'M1_ZONING'] <- fourplex_description

# In sites inventory maps, where zoning is NA, indicate it's
# fourplex if it's fourplex in Fall 2023 rezoning
final[is.na(final$M1_ZONING) 
      & ((!is.na(final$M4_ZONING) & (final$M4_ZONING == fourplex_description)) | (!is.na(final$M5_ZONING) & (final$M5_ZONING == fourplex_description))),
      "M1_ZONING"] <- fourplex_description
final[is.na(final$M2_ZONING) 
      & ((!is.na(final$M4_ZONING) & (final$M4_ZONING == fourplex_description)) | (!is.na(final$M5_ZONING) & (final$M5_ZONING == fourplex_description))),
      "M2_ZONING"] <- fourplex_description
final[is.na(final$M3_ZONING) 
      & ((!is.na(final$M4_ZONING) & (final$M4_ZONING == fourplex_description)) | (!is.na(final$M5_ZONING) & (final$M5_ZONING == fourplex_description))),
      "M3_ZONING"] <- fourplex_description


sixplex_description <-  "Increased density up to six units"
final['is_corner'] <- final$mapblklot %in% corner$mapblklot
final[!is.na(final$M1_ZONING) & final$M1_ZONING == fourplex_description & final$is_corner, 'M1_ZONING'] <- sixplex_description
final[!is.na(final$M2_ZONING) & final$M2_ZONING == fourplex_description & final$is_corner, 'M2_ZONING'] <- sixplex_description
final[!is.na(final$M3_ZONING) & final$M3_ZONING == fourplex_description & final$is_corner, 'M3_ZONING'] <- sixplex_description
final[!is.na(final$M4_ZONING) & final$M4_ZONING == fourplex_description & final$is_corner, 'M4_ZONING'] <- sixplex_description
final[!is.na(final$M5_ZONING) & final$M5_ZONING == fourplex_description & final$is_corner, 'M5_ZONING'] <- sixplex_description
final[!is.na(final$M6_ZONING_base) & final$M6_ZONING_base == fourplex_description & final$is_corner, 'M6_ZONING_base'] <- sixplex_description

final <- st_sf(final)
final <- st_transform(final[1:nrow(final),], crs = 4326)
saveRDS(final, file.path(PROJECT_DIR, 'five_rezonings.RDS'))

}


if (sys.nframe() == 0) {
  merge_scenario()
}
