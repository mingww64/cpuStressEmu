import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
from scipy.optimize import curve_fit

# Load the processed dataset from the previous step
# This file should contain the correct column names and calculated Thermal Resistance
try:
    df_processed = pd.read_csv("cpu_cooling_data_processed.csv")
except FileNotFoundError:
    print("Error: 'cpu_cooling_data_processed.csv' not found. Please ensure the previous analysis step was completed successfully.")
    # As a fallback for demonstration, if the file is missing, I might need to re-run the data processing from the original file.
    # For now, I will assume the file exists from the previous successful execution.
    # If running this step independently, the data loading and prep from the previous step would be needed here.
    raise

# Rename columns for clarity if they are the new ones, or define them if they are the old ones.
# From the previous successful run, the columns are:
# 'CPU_Fan_RPM' and 'Thermal_Resistance_Calculated'
# Check if these columns exist
expected_rpm_col = 'CPU_Fan_RPM'
expected_rth_col = 'Thermal_Resistance_Calculated' # This was calculated in the previous step.

# Check if the 'Thermal_Resistance_Calculated' column exists from previous step.
# If not, we might have 'Thermal_Resistance_Recalculated' or need to handle naming.
# Let's assume the file "cpu_cooling_data_processed.csv" uses 'Thermal_Resistance_Calculated'
# and 'CPU_Fan_RPM' as these were the final names used in the previous successful Python script.

if expected_rpm_col not in df_processed.columns or expected_rth_col not in df_processed.columns:
    print(f"Error: Expected columns '{expected_rpm_col}' or '{expected_rth_col}' not found in 'cpu_cooling_data_processed.csv'.")
    print(f"Available columns: {df_processed.columns.tolist()}")
    # Attempt to map from common alternatives if previous step used slightly different naming in output CSV
    # This is a fallback - ideally the column names are consistent.
    if 'CPU Fan RPM (RPM)' in df_processed.columns and 'Thermal_Resistance_Recalculated' in df_processed.columns:
        print("Found alternative column names. Using 'CPU Fan RPM (RPM)' and 'Thermal_Resistance_Recalculated'.")
        df_processed.rename(columns={
            'CPU Fan RPM (RPM)': expected_rpm_col,
            'Thermal_Resistance_Recalculated': expected_rth_col
        }, inplace=True)
    elif 'CPU_Fan_RPM' in df_processed.columns and 'Thermal_Resistance_Recalculated' in df_processed.columns: # If my 'Calculated' became 'Recalculated'
        print("Found alternative column names. Using 'CPU_Fan_RPM' and 'Thermal_Resistance_Recalculated'.")
        df_processed.rename(columns={
            'Thermal_Resistance_Recalculated': expected_rth_col
        }, inplace=True)
    else:
        raise KeyError("Could not find suitable columns for RPM and Thermal Resistance in the processed data.")


# Prepare data for curve fitting
x_data = df_processed[expected_rpm_col].values
y_data = df_processed[expected_rth_col].values

# Sort data by RPM for cleaner plotting
sort_indices = np.argsort(x_data)
x_data_sorted = x_data[sort_indices]
y_data_sorted = y_data[sort_indices]

# Define the physics-based model function
# R_th(RPM) = R_fixed + C / RPM^n
def thermal_resistance_model(rpm, r_fixed, c, n):
    return r_fixed + c / (rpm**n)

# Provide initial guesses and bounds for the parameters
# R_fixed should be positive, C positive, n likely between 0.1 and 1.0 (common physics suggests 0.5-0.8)
initial_guesses = [min(y_data_sorted)*0.5, # R_fixed: a bit less than min Rth
                   (max(y_data_sorted) - min(y_data_sorted)) * (x_data_sorted[len(x_data_sorted)//2]**0.5), # C
                   0.7] # n
bounds_lower = [0, 0, 0.1]
bounds_upper = [max(y_data_sorted), np.inf, 1.5] # Upper bound for n, e.g. 1.5

params = None
pcov = None
model_fit_successful = False

try:
    params, pcov = curve_fit(thermal_resistance_model,
                             x_data_sorted, y_data_sorted,
                             p0=initial_guesses,
                             bounds=(bounds_lower, bounds_upper),
                             maxfev=5000) # Increased max function evaluations
    r_fixed_fit, c_fit, n_fit = params
    model_fit_successful = True
    print("\nFitted Model Parameters:")
    print(f"  R_fixed = {r_fixed_fit:.4f} °C/W")
    print(f"  C = {c_fit:.4f}")
    print(f"  n = {n_fit:.4f}")

    # Calculate y_model using the fitted parameters
    y_model = thermal_resistance_model(x_data_sorted, r_fixed_fit, c_fit, n_fit)

except RuntimeError:
    print("\nCould not fit the model. Optimal parameters not found with current settings/initial guesses.")
    print("This can happen if the data doesn't conform well to the model or if initial guesses/bounds are too far off.")
    print("Proceeding with visualization of raw data only.")
except ValueError as e:
    print(f"\nValueError during curve fitting: {e}")
    print("This might be due to incompatible bounds or initial guesses. Proceeding with raw data viz.")


# Plotting the experimental data and the fitted model
plt.figure(figsize=(12, 7))
plt.scatter(x_data_sorted, y_data_sorted, label='Experimental Data', alpha=0.6, s=30, color='skyblue')

if model_fit_successful:
    plt.plot(x_data_sorted, y_model, color='red', linewidth=2.5, label=f'Fitted Model: $R_{{th}} = {r_fixed_fit:.3f} + {c_fit:.0f} / RPM^{{{n_fit:.3f}}}$')

plt.title('Thermal Resistance vs. CPU Fan RPM with Fitted Model', fontsize=16)
plt.xlabel(f'{expected_rpm_col.replace("_", " ")} (RPM)', fontsize=14)
plt.ylabel(f'{expected_rth_col.replace("_", " ")} (°C/W)', fontsize=14) # Used expected_rth_col for consistency
plt.legend(fontsize=12)
plt.grid(True, linestyle='--', alpha=0.7)
plt.tight_layout()
plt.savefig("thermal_resistance_model_fit.png")
# plt.show() # Not needed if saving

if model_fit_successful:
    # Discussion of the "Sweet Spot"
    # The "sweet spot" is where the rate of change of R_th starts to diminish significantly.
    # We can look at the derivative of the fitted model: d(R_th)/d(RPM) = -n * C * RPM^(-n-1)
    # Let's calculate this derivative
    derivative_r_th = -n_fit * c_fit * (x_data_sorted**(-n_fit - 1))

    plt.figure(figsize=(12, 7))
    plt.plot(x_data_sorted, derivative_r_th, color='green', linewidth=2, label='$dR_{th}/d(RPM)$')
    plt.title('Derivative of Thermal Resistance vs. CPU Fan RPM', fontsize=16)
    plt.xlabel(f'{expected_rpm_col.replace("_", " ")} (RPM)', fontsize=14)
    plt.ylabel('Rate of Change of $R_{th}$ ($°C \cdot W^{-1} \cdot RPM^{-1}$)', fontsize=14)
    plt.axhline(0, color='black', linewidth=0.5, linestyle='--') # Reference line
    # Highlight a potential "sweet spot" range - e.g., where the derivative becomes less steep
    # This is somewhat subjective without a clear cost function for RPM (noise, power)
    # For example, find where the derivative is, say, 10% or 20% of its maximum absolute value near low RPMs.
    try:
        max_abs_derivative_low_rpm = np.abs(derivative_r_th[x_data_sorted < (min(x_data_sorted) + 0.2*(max(x_data_sorted)-min(x_data_sorted)))]).max() # Max derivative in first 20% of RPM range
        sweet_spot_threshold_derivative = -0.1 * max_abs_derivative_low_rpm # e.g. 10% of max change
        potential_sweet_spot_rpm = x_data_sorted[derivative_r_th < sweet_spot_threshold_derivative][-1] # Last RPM before derivative gets too flat
        plt.axvline(potential_sweet_spot_rpm, color='orange', linestyle='--', label=f'Potential Sweet Spot Zone (RPM > {potential_sweet_spot_rpm:.0f})')
        print(f"\nPotential 'sweet spot' discussion:")
        print(f"  The rate of reduction in thermal resistance diminishes as RPM increases.")
        print(f"  A potential sweet spot might be considered around {potential_sweet_spot_rpm:.0f} RPM,")
        print(f"  after which the improvements per additional RPM become significantly smaller.")
        print(f"  (Based on derivative falling below 10% of its initial max rate of change).")

    except IndexError:
        print("\nCould not programmatically determine a specific sweet spot from derivative trend with current logic.")
    except Exception as e:
        print(f"\nError during sweet spot analysis: {e}")


    plt.legend(fontsize=12)
    plt.grid(True, linestyle='--', alpha=0.7)
    plt.tight_layout()
    plt.savefig("thermal_resistance_derivative.png")
    # plt.show()

print("\nModel fitting and sweet spot analysis complete.")
print("Plots saved as 'thermal_resistance_model_fit.png' and 'thermal_resistance_derivative.png'.")