"""Dataset-level "Map" tab: /dataset/<id>/map renders all WMS resources."""
from flask import Blueprint

import ckan.plugins.toolkit as tk

blueprint = Blueprint("amconnect", __name__)


@blueprint.route("/dataset/<id>/map")
def dataset_map(id):
    context = {"user": tk.g.user, "auth_user_obj": tk.g.userobj}
    try:
        pkg_dict = tk.get_action("package_show")(context, {"id": id})
    except (tk.ObjectNotFound, tk.NotAuthorized):
        return tk.abort(404, tk._("Dataset not found"))
    return tk.render("amconnect/dataset_map.html",
                     {"pkg_dict": pkg_dict, "pkg": pkg_dict, "dataset_type": pkg_dict["type"]})
