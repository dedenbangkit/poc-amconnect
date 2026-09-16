"""ckanext-amconnect: AMConnect proof-of-concept extension.

What it adds to CKAN:

* four dataset-level metadata fields (country, commodity, data_type, access_level)
* a ``wms_layer`` resource field and the ``WMS`` resource format
* an OpenLayers resource view that renders any WMS endpoint (local GeoServer
  or external/federated) directly in CKAN
* a "Map" tab on the dataset page showing all WMS resources of the dataset
* ``ckan amconnect seed`` to create the example dataset

Two plugins: ``amconnect`` (everything above except the view) and
``amconnect_wms_view`` (the IResourceView).  Enable both.

Anything GIS-server specific lives in ``wms.py`` so a future GeoNode-backed
provider can be added without touching the CKAN plumbing.
"""
import ckan.plugins as p
import ckan.plugins.toolkit as tk

from ckanext.amconnect import cli, helpers, views, wms

# Dataset-level custom fields. Kept as a simple list so the same definition
# drives the schema, the form and the display template.
DATASET_FIELDS = (
    {"name": "country", "label": "Country"},
    {"name": "commodity", "label": "Commodity"},
    {"name": "data_type", "label": "Data type",
     "choices": ("geospatial", "tabular", "document", "other")},
    {"name": "access_level", "label": "Access level",
     "choices": ("public-view", "public-download", "restricted", "internal")},
)


class AmconnectPlugin(p.SingletonPlugin, tk.DefaultDatasetForm):
    """Metadata fields, resource field, helpers, Map tab and CLI."""
    p.implements(p.IConfigurer)
    p.implements(p.IDatasetForm)
    p.implements(p.ITemplateHelpers)
    p.implements(p.IBlueprint)
    p.implements(p.IClick)

    # ------------------------------------------------------------ IConfigurer
    def update_config(self, config_):
        tk.add_template_directory(config_, "templates")
        tk.add_resource("assets", "amconnect")

    # ---------------------------------------------------------- IDatasetForm
    def is_fallback(self):
        return True

    def package_types(self):
        return []

    def _modify_package_schema(self, schema):
        for field in DATASET_FIELDS:
            validators = [tk.get_validator("ignore_missing"),
                          tk.get_validator("unicode_safe")]
            if "choices" in field:
                validators.append(tk.get_validator("one_of")(field["choices"]))
            validators.append(tk.get_converter("convert_to_extras"))
            schema.update({field["name"]: validators})
        schema["resources"].update({
            "wms_layer": [tk.get_validator("ignore_missing"),
                          tk.get_validator("unicode_safe")],
        })
        return schema

    def create_package_schema(self):
        return self._modify_package_schema(super().create_package_schema())

    def update_package_schema(self):
        return self._modify_package_schema(super().update_package_schema())

    def show_package_schema(self):
        schema = super().show_package_schema()
        for field in DATASET_FIELDS:
            schema.update({field["name"]: [
                tk.get_converter("convert_from_extras"),
                tk.get_validator("ignore_missing")]})
        schema["resources"].update({
            "wms_layer": [tk.get_validator("ignore_missing"),
                          tk.get_validator("unicode_safe")],
        })
        return schema

    # ------------------------------------------------------ ITemplateHelpers
    def get_helpers(self):
        return {
            "amconnect_dataset_fields": lambda: DATASET_FIELDS,
            "amconnect_wms_layers": helpers.wms_layers_for_package,
            "amconnect_wms_url": wms.wms_base_url,
        }

    # ------------------------------------------------------------ IBlueprint
    def get_blueprint(self):
        return [views.blueprint]

    # ---------------------------------------------------------------- IClick
    def get_commands(self):
        return [cli.amconnect]


class AmconnectWmsViewPlugin(p.SingletonPlugin):
    """The OpenLayers WMS resource view (``amconnect_wms_view``).

    Kept as a separate plugin class because IDatasetForm and IResourceView
    both define ``setup_template_variables`` and would clash on one class.
    """
    p.implements(p.IResourceView, inherit=True)

    def info(self):
        return {
            "name": "amconnect_wms_view",
            "title": "WMS Map",
            "icon": "map",
            "default_title": "Map preview",
            "iframed": False,
            "always_available": False,
            "schema": {
                "wms_layer": [tk.get_validator("ignore_missing"),
                              tk.get_validator("unicode_safe")],
            },
        }

    def can_view(self, data_dict):
        return wms.is_wms_resource(data_dict["resource"])

    def setup_template_variables(self, context, data_dict):
        resource = data_dict["resource"]
        view = data_dict.get("resource_view") or {}
        return {"wms_layer": wms.layer_for(resource, view.get("wms_layer"))}

    def view_template(self, context, data_dict):
        return "amconnect/wms_view.html"

    def form_template(self, context, data_dict):
        return "amconnect/wms_form.html"

