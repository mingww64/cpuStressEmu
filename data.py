import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns

# Load the dataset
file_path = "cpu_cooling_data_controlled.csv"
df = pd.read_csv(file_path)

# 1. Clean column names
df.columns = df.columns.str.strip()

# Identify relevant columns for calculation
t_case_col = 'CPU_Temp_C'
t_ambient_col = 'Ambient_Temp_C'
p_cpu_col = 'CPU_Power_W_Actual'
fan_rpm_col = 'CPU_Fan_RPM'



# 2. Handle potential division by zero or very small power values for P_cpu
# If CPU Package Power is very low or zero, thermal resistance calculation can be problematic.
# Let's check the distribution of CPU Package Power.
print("\nCPU Package Power (W) description:")
print(df[p_cpu_col].describe())

# We should filter out rows where CPU Package Power is <= 0 to avoid division by zero or meaningless results.
# However, the min value is 65W, so division by zero is not an issue here.

# 3. Recalculate Thermal Resistance
# R_th = (T_case - T_ambient) / P_cpu
df['Thermal_Resistance_Recalculated'] = (df[t_case_col] - df[t_ambient_col]) / df[p_cpu_col]

# Compare recalculated with original (if needed, but we will use the recalculated one for consistency)
print("\nRecalculated Thermal Resistance column description:")
print(df['Thermal_Resistance_Recalculated'].describe())
print(f"Number of NaNs in Recalculated Thermal Resistance: {df['Thermal_Resistance_Recalculated'].isnull().sum()}")


# Check if there are any infinite values in the recalculated column due to P_cpu being zero (already checked it's not an issue)
if np.isinf(df['Thermal_Resistance_Recalculated']).any():
    print("\nWarning: Infinite values found in recalculated thermal resistance. This might be due to CPU Power being zero.")
    # df = df[~np.isinf(df['Thermal_Resistance_Recalculated'])] # Optionally remove them

# For the analysis, we'll use the fan RPM and the recalculated thermal resistance.
# Let's remove rows where recalculated thermal resistance might be NaN (if any inputs were NaN, though not the case here)
df_analysis = df[[fan_rpm_col, 'Thermal_Resistance_Recalculated']].copy()
df_analysis.dropna(subset=['Thermal_Resistance_Recalculated'], inplace=True)


# 4. Analyze the relationship
plt.figure(figsize=(10, 6))
sns.scatterplot(data=df_analysis, x=fan_rpm_col, y='Thermal_Resistance_Recalculated', alpha=0.6)
# Add a trend line (regression line)
sns.regplot(data=df_analysis, x=fan_rpm_col, y='Thermal_Resistance_Recalculated', scatter=False, color='red')

plt.title('Thermal Resistance vs. CPU Fan RPM')
plt.xlabel('CPU Fan RPM (RPM)')
plt.ylabel('Recalculated Thermal Resistance (°C/W)')
plt.grid(True)
plt.tight_layout() # Ensure labels are not cut off
plt.savefig("thermal_resistance_vs_fan_rpm.png") # Save the plot
# plt.show() # Display the plot - not needed if saving

# Calculate the Pearson correlation coefficient
correlation = df_analysis[fan_rpm_col].corr(df_analysis['Thermal_Resistance_Recalculated'])
print(f"\nCorrelation between {fan_rpm_col} and Recalculated Thermal Resistance: {correlation:.4f}")

# Output the cleaned and processed data with recalculated thermal resistance
df.to_csv("cpu_cooling_data_processed.csv", index=False)

print("\nAnalysis complete. Plot saved as thermal_resistance_vs_fan_rpm.png")
print("Processed data saved as cpu_cooling_data_processed.csv")

# Define column names that the plotting functions will use.
# These names should match what's in cpu_cooling_data_processed.csv' after stripping.
# Based on previous successful processing of the original data, assuming these names:
COL_ACTUAL_PPT = 'CPU_Power_W_Actual'
COL_SET_PPT = 'Set_PPT_W'
COL_CPU_TEMP = 'CPU_Temp_C'
COL_FAN_RPM = 'CPU_Fan_RPM'
COL_AMBIENT_TEMP = 'Ambient_Temp_C'
COL_RTH_CALCULATED = 'Thermal_Resistance_Calculated' # Will be calculated if not present

# Primary data file is now cpu_cooling_data_processed.csv'
primary_data_file = "cpu_cooling_data_processed.csv"

try:
    df = pd.read_csv(primary_data_file)
    print(f"Successfully loaded '{primary_data_file}'.")
    
    df.columns = df.columns.str.strip()
    print(f"Stripped column names: {df.columns.tolist()}")

    # Verify necessary columns exist
    required_cols_check = [COL_ACTUAL_PPT, COL_SET_PPT, COL_CPU_TEMP, COL_FAN_RPM, COL_AMBIENT_TEMP]
    missing_cols = [col for col in required_cols_check if col not in df.columns]
    if missing_cols:
        print(f"Error: Critical columns {missing_cols} are missing from '{primary_data_file}' after stripping.")
        print(f"Available columns: {df.columns.tolist()}")
        # Attempt to map common alternatives if known, otherwise raise error
        # Example: if 'CPU Temperature (C)' was expected but 'CPU_Temp_C' is present.
        # For now, strict check.
        raise KeyError(f"Cannot proceed, missing essential columns in '{primary_data_file}': {missing_cols}")

    # Calculate thermal resistance if not already present
    if COL_RTH_CALCULATED not in df.columns:
        print(f"'{COL_RTH_CALCULATED}' not found, calculating it...")
        power_threshold = 1.0
        valid_power_mask = df[COL_ACTUAL_PPT] >= power_threshold
        
        if (~valid_power_mask).any():
            print(f"Info: { (~valid_power_mask).sum()} rows have '{COL_ACTUAL_PPT}' < {power_threshold}W. Rth will be NaN for these.")

        df[COL_RTH_CALCULATED] = np.nan # Initialize column
        df.loc[valid_power_mask, COL_RTH_CALCULATED] = \
            (df.loc[valid_power_mask, COL_CPU_TEMP] - df.loc[valid_power_mask, COL_AMBIENT_TEMP]) / df.loc[valid_power_mask, COL_ACTUAL_PPT]
        print(f"Calculated '{COL_RTH_CALCULATED}'. {df[COL_RTH_CALCULATED].isnull().sum()} NaNs in Rth.")
    else:
        print(f"'{COL_RTH_CALCULATED}' column already present in the data.")
        
    # Save this potentially modified dataframe (with calculated Rth) as the new 'processed' file for subsequent steps.
    # This ensures that the modeling step can use this version.
    df.to_csv("cpu_cooling_data_processed.csv", index=False)
    print("Saved the processed data (from download.csv, with Rth) to 'cpu_cooling_data_processed.csv'")


except FileNotFoundError:
    print(f"Fatal Error: The specified data file '{primary_data_file}' was not found.")
    print("Please ensure the file is correctly uploaded and named.")
    raise 
except Exception as e:
    print(f"Fatal Error: An error occurred during loading or initial processing of '{primary_data_file}': {e}")
    raise

# --- Plot 1: Actual PPT vs. Set PPT ---
plt.figure(figsize=(10, 6))
sns.scatterplot(data=df, x=COL_SET_PPT, y=COL_ACTUAL_PPT, alpha=0.6, hue=COL_FAN_RPM, palette='coolwarm_r', s=50)
if df[COL_SET_PPT].notna().all() and df[COL_ACTUAL_PPT].notna().all(): # Check for NaNs before min/max
    max_val = max(df[COL_SET_PPT].max(), df[COL_ACTUAL_PPT].max())
    min_val = min(df[COL_SET_PPT].min(), df[COL_ACTUAL_PPT].min())
    if pd.notna(min_val) and pd.notna(max_val): # Ensure min_val and max_val themselves are not NaN
        plt.plot([min_val, max_val], [min_val, max_val], 'k--', lw=2, label='Ideal (Actual = Set)')
    else:
        print("Warning: Could not determine range for identity line in 'Actual PPT vs Set PPT' due to NaN in min/max power values.")
else:
     print("Warning: Skipping identity line in 'Actual PPT vs Set PPT' due to NaN values in power columns.")
plt.title('Actual CPU Power vs. Set Power Target (PPT)', fontsize=16)
plt.xlabel('Set PPT (W)', fontsize=14)
plt.ylabel('Actual CPU Power (W)', fontsize=14)
plt.legend(title='CPU Fan RPM')
plt.grid(True, linestyle=':', alpha=0.7)
plt.tight_layout()
plt.savefig("Actual_PPT_vs_Set_PPT.png")
print("Plot 'Actual_PPT_vs_Set_PPT.png' saved.")

# --- Plot 2: Temperature vs. Power ---
plt.figure(figsize=(10, 6))
scatter = sns.scatterplot(data=df, x=COL_ACTUAL_PPT, y=COL_CPU_TEMP, hue=COL_FAN_RPM, size=COL_AMBIENT_TEMP, palette='viridis', alpha=0.7, sizes=(20, 200))
plt.title('CPU Temperature vs. Actual CPU Power', fontsize=16)
plt.xlabel('Actual CPU Power (W)', fontsize=14)
plt.ylabel('CPU Temperature (°C)', fontsize=14)
handles, labels = scatter.get_legend_handles_labels()
plt.legend(title='CPU Fan RPM / Ambient Temp', bbox_to_anchor=(1.05, 1), loc='upper left')
plt.grid(True, linestyle=':', alpha=0.7)
plt.tight_layout(rect=[0, 0, 0.85, 1]) 
plt.savefig("Temp_vs_Power.png")
print("Plot 'Temp_vs_Power.png' saved.")

# --- Plot 3: Temperature vs. RPM ---
plt.figure(figsize=(10, 6))
scatter_temp_rpm = sns.scatterplot(data=df, x=COL_FAN_RPM, y=COL_CPU_TEMP, hue=COL_ACTUAL_PPT, size=COL_AMBIENT_TEMP, palette='magma', alpha=0.7, sizes=(20,200))
plt.title('CPU Temperature vs. CPU Fan RPM', fontsize=16)
plt.xlabel('CPU Fan RPM', fontsize=14)
plt.ylabel('CPU Temperature (°C)', fontsize=14)
plt.legend(title='CPU Power (W) / Ambient Temp', bbox_to_anchor=(1.05, 1), loc='upper left')
plt.grid(True, linestyle=':', alpha=0.7)
plt.tight_layout(rect=[0, 0, 0.85, 1]) 
plt.savefig("Temp_vs_RPM.png")
print("Plot 'Temp_vs_RPM.png' saved.")

# --- Plot 4: Distributions of Key Variables ---
fig, axes = plt.subplots(2, 2, figsize=(14, 10))
fig.suptitle('Distributions of Key Experimental Variables', fontsize=18, y=1.02)

sns.histplot(df[COL_CPU_TEMP], kde=True, ax=axes[0, 0], color='skyblue')
axes[0, 0].set_title('CPU Temperature (°C)', fontsize=14)
axes[0, 0].set_xlabel('')
axes[0, 0].set_ylabel('Frequency', fontsize=12)

sns.histplot(df[COL_AMBIENT_TEMP], kde=True, ax=axes[0, 1], color='lightgreen')
axes[0, 1].set_title('Ambient Temperature (°C)', fontsize=14)
axes[0, 1].set_xlabel('')
axes[0, 1].set_ylabel('Frequency', fontsize=12)

sns.histplot(df[COL_ACTUAL_PPT], kde=True, ax=axes[1, 0], color='salmon')
axes[1, 0].set_title('Actual CPU Power (W)', fontsize=14)
axes[1, 0].set_xlabel('')
axes[1, 0].set_ylabel('Frequency', fontsize=12)

sns.histplot(df[COL_FAN_RPM], kde=True, ax=axes[1, 1], color='gold')
axes[1, 1].set_title('CPU Fan RPM', fontsize=14)
axes[1, 1].set_xlabel('')
axes[1, 1].set_ylabel('Frequency', fontsize=12)

for ax_row in axes:
    for ax in ax_row:
        ax.grid(True, linestyle=':', alpha=0.5)
        ax.tick_params(axis='x', labelsize=10)
        ax.tick_params(axis='y', labelsize=10)

plt.tight_layout(rect=[0, 0, 1, 0.98]) 
plt.savefig("Key_Variables_Distribution.png")
print("Plot 'Key_Variables_Distribution.png' saved.")

print("\nPython script execution for additional plots using 'download.csv' complete.")

